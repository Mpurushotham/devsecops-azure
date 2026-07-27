# Interview notes — defending this platform

Short answers you can actually say out loud, each structured the same way:
**what** was built, **why** that choice, **what it cost**, and **what would
change it**. The last part matters most — an engineer who can only defend a
decision has not really made one.

Two rules that will serve you better than any individual answer:

- **Lead with the trade-off, not the feature.** "We use workload identity" is a
  fact. "We removed every long-lived credential, and the cost is that local
  development needs `az login` and Terraform ordering gets stricter" is an
  engineering position.
- **Say what you have not proven.** [COVERAGE.md](COVERAGE.md) splits everything
  into proven / coded / absent. Volunteering that split is far stronger than
  being caught by it.

---

## 1. Architecture and Azure

**"Walk me through the platform."**

Four layers, one direction of dependency: network → cluster → identity → data,
with observability underneath everything because every other module ships
diagnostics into it. Environments are composition roots that wire the same five
modules with different sizing. A workload gets an image and a few Helm values;
the platform supplies identity, networking, secrets and telemetry.

**"Why Azure CNI Overlay with Cilium instead of classic CNI or a service mesh?"**

*What:* pod IPs come from an overlay CIDR; NetworkPolicy is enforced by Cilium
in eBPF.

*Why:* with classic CNI, 30 nodes × 110 pods needs ~3,300 VNet addresses — a /20
per environment before growth, and a seasonal scale-out can exhaust the subnet.
Overlay decouples pod density from address planning entirely.

*Cost:* no L7 policy and no mTLS between services. At ~200 pods a sidecar mesh
would add roughly 20 vCPU and 20 GB of memory — about €1,400/month spent on
proxies rather than on serving traffic.

*Changes it:* per-service mTLS becoming a compliance requirement, or needing
method- and path-level authorization internally. Cilium Service Mesh is the
first thing to evaluate, since it is already the data plane.

**"Private API server in production but not elsewhere — isn't that inconsistent?"**

It is deliberate asymmetry, not inconsistency. Production has no public
endpoint. Non-production does, restricted to explicit CIDRs, because a private
cluster needs self-hosted runners in the VNet — roughly €150/month plus
maintenance, per environment. Paying that three times to protect environments
with no customer data would be poor judgement.

The safeguard is that "public and unrestricted" cannot be applied by accident: a
required variable with a length validation, plus a plan-time precondition in the
module. Forgetting the CIDR list fails the plan.

**"Why NAT gateway when AKS gives you outbound by default?"**

Payment processors allowlist source IPs. Default AKS egress uses load-balancer
addresses that can change when the cluster scales — so the integration would
break precisely during a traffic spike, when scaling happens. €35/month against
one failed settlement window. It is a business-integration requirement that
happens to be implemented in networking.

---

## 2. Security

**"How do you handle secrets?"**

By trying not to have any. Three OIDC federation relationships replace three
stored credentials: CI → Entra, Azure DevOps → Entra, pod → Entra. No registry
password, no service principal secret, no database password — the app connects
with `Authentication=Active Directory Default`.

The part worth emphasising: each federated credential is pinned to a single
subject claim — `repo:org/name:environment:prod`, or
`system:serviceaccount:payments:payments-api`. A compromised staging pod
requesting a production token gets an authentication failure, because the claim
does not match. The claim is the boundary.

What genuinely must be stored — payment processor API keys — lives in Key Vault
and is mounted by the CSI driver at pod start with a 2-minute rotation interval.
It never becomes a long-lived Kubernetes Secret.

**"How do you know those controls actually work?"**

Because three of them refused me during verification, which is the only real
proof:

1. Pod Security `restricted` rejected a debug pod that omitted capability drops.
2. The namespace default-deny NetworkPolicy blocked DNS for an ad-hoc pod.
3. The workload's NetworkPolicy blocked AMQP to RabbitMQ until an explicit allow
   rule was added — and that rule went in through git and Argo CD, so the
   exception is reviewable in a diff rather than applied by hand.

A control that has never said no is a control nobody has tested.

**"Walk me through your CVSS gating."**

Policy: CVSS ≥ 9.0 blocks the build, 7.0–8.9 warns and opens a ticket, below
that is logged.

The interesting part is that the original implementation was **wrong**, and
fixing it is the better story. Every gate read the SARIF `level` field as a
severity proxy — but Trivy maps *both* CRITICAL and HIGH to `level: "error"`. So
HIGH findings were blocking builds the policy said should only warn, and MEDIUM
was reported as HIGH.

The damage is worse than a mislabelled log line: a gate that blocks on findings
the policy accepts trains people to bypass it, which is how the CRITICAL that
matters gets waved through. Scanners publish the real score in
`properties.security-severity`; there is now one shared script that reads it,
and six divergent inline implementations are gone.

**"Why is `curl | sh` banned in your pipelines?"**

Because the tools installed that way are syft and grype — they *produce* the
SBOM and the vulnerability report. A compromised installer compromises the
evidence as well as the build. Everything is now a pinned release asset verified
against the publisher's checksums. Semgrep enforces it (`gha-curl-pipe-shell`),
and the repo scans clean at ERROR level.

---

## 3. Delivery and GitOps

**"Why does the pipeline not deploy?"**

Three consequences, in order of importance:

1. **Blast radius.** A compromised pipeline can propose a change, not make one.
   Production requires a merge, which requires review.
2. **Rollback.** `git revert` — the same mechanism as the forward path, so it is
   exercised constantly instead of being an untested emergency procedure.
3. **Drift.** Argo CD self-heals, so the cluster provably matches git. "What is
   running?" is answered by reading a file, not by querying a cluster.

*Cost:* deployment is asynchronous, so the pipeline polls for rollout status.
Self-heal reverts manual `kubectl` edits, which is painful the first time
someone hotfixes by hand — and is exactly the property that makes the cluster
trustworthy during an incident review.

*Demonstrated:* I deleted a Deployment on the live cluster and Argo CD restored
it in about 25 seconds.

**"How does a change actually reach production?"**

CI builds, scans, signs with cosign and attests an SBOM. It then commits a
digest change for dev, or opens a PR for staging and production. Argo CD
reconciles. The image is referenced by **digest, not tag**, because a tag is
mutable — a digest is the only way to know that what is running is what was
scanned and signed.

**"Why one Helm chart for every service?"**

The chart is the platform contract expressed as code: non-root, dropped
capabilities, read-only rootfs, resource requests, PDB, zone spread,
NetworkPolicy, digest pinning. A team supplies an image and a few values and
cannot forget any of it.

It is enforced three times — the chart sets it, CI asserts 17 properties on the
rendered output, and admission control rejects violations. Belt, braces, and a
third thing, because the failure mode of a missing security context is silent.

---

## 4. Reliability and scale

**"How would you handle a seasonal traffic spike?"**

Four layers at different timescales: KEDA on queue depth (~15s, predictive),
HPA on CPU/memory (~30s, reactive), cluster autoscaler on pending pods (~90s),
and a warm floor of overprovisioned capacity.

The ordering is the point. CPU is a *lagging* indicator for an IO-bound API — by
the time it rises, requests are already queuing. KEDA scaling on RabbitMQ depth
reacts before pods saturate.

The tuning is deliberately asymmetric: scale up with zero stabilisation window,
scale down over five minutes. The two failure modes are not symmetric — scaling
up late drops traffic and revenue during peak; scaling down late costs about
€0.75 for ten extra nodes for fifteen minutes.

**Be honest:** this is reasoned, not load-tested. Say so.

**"Your rollouts use `maxUnavailable: 0`. Why?"**

Surge first, then terminate — capacity never dips below the current level during
a deploy. A 25% dip while rolling is a real outage during peak season. It costs
one extra pod's worth of resource for the duration of the rollout.

**"Why Business Critical SQL? That is expensive."**

~€1,800/month more than General Purpose, and it buys three things: local SSD (a
~5× latency improvement that shows up directly in API p99), a free read replica
that takes reporting load off the primary during peaks, and sub-10-second
failover.

The read replica alone justifies it — the alternative is provisioning a second
General Purpose database for reporting, which costs more and adds replication
lag to reason about. Revisit if replica utilisation stays below ~20%.

---

## 5. Observability

**"How do you keep observability affordable without going blind?"**

Two decisions.

**Split the log stores by purpose.** Log Analytics is the compliance store —
immutable, 180-day retention, ~€2.30/GB, low volume. Elastic is the debugging
store — full-text search, ~€0.40/GB, high volume, short retention. Sending
everything to both roughly doubles the bill for no diagnostic gain: nobody greps
audit logs during an incident, and nobody produces compliance evidence from a
14-day index. At ~500 GB/month that split saves about €950/month.

**Tail sampling, not head sampling.** Head sampling at 10% discards 90% of
errors — precisely the traces anyone wants during an incident. The collector
keeps 100% of errors, 100% of requests slower than 1s and 100% of payment
flows, and samples the boring successful traffic at 5%. Roughly 70% cost
reduction with no loss of diagnostic value.

**"Why does the collector sit in the middle?"**

Sampling and PII scrubbing become platform concerns rather than per-service
ones. Changing observability vendor is a collector config change, not a redeploy
of every service. And a service that logs too much is contained by platform
configuration rather than by a code change in someone else's repository.

**"What do you page on?"**

Multi-window SLO error-budget burn: 14.4× over an hour pages; 6× over six hours
opens a ticket. CPU, memory and pod restarts are dashboards, never pages. A
service at 90% CPU meeting its latency objective is correctly sized — paging for
it teaches people to ignore alerts, which is how the real page gets missed.

---

## 6. The .NET migration

**"How would you move .NET Framework services off VMs?"**

Containerise on Windows first, then port to .NET 10 — not the other way round.

Porting first leaves the service on unmanaged VMs for the whole 6–12 month
effort, with its own deployment path, monitoring and patching, and no benefit
until the very end. Containerising first takes 2–4 weeks and immediately buys
rolling deploys, autoscaling, Key Vault secrets, centralised telemetry and the
same GitOps flow as everything else. The port then becomes an incremental change
to a service that is already operationally modern — and it can be paused if
priorities shift without leaving anything half-finished.

*Cost:* Windows nodes are roughly twice the per-core price, images are ~5 GB
against ~300 MB, and `readOnlyRootFilesystem` cannot be set — so there is a
scoped Kyverno exception, labelled to those workloads so it disappears with the
pool.

*The discipline:* the Windows node pool is tracked as a migration metric and is
expected to be **deleted**. When the workload count on it reaches zero, the pool
goes and the ADR closes. Otherwise the last 10% never gets done.

---

## 7. Terraform and operational judgement

**"What did deploying this for real teach you?"**

Nine defects, and `terraform validate` had been passing cleanly for every one.
They arrived in three waves, and the pattern is the useful part — each layer
catches a class the previous one structurally cannot:

- **`plan` caught the dependency graph.** Eleven resources gated `count` on an
  id computed by another resource in the same apply. Terraform cannot evaluate
  that at plan time. It affected all four environments.
- **`apply` caught what Azure actually accepts.** A Kubernetes version that had
  moved to LTS-only; subnets needing service endpoints before appearing in a
  PaaS ACL; storage ACLs rejecting a `/32`; a VM size not offered on that
  subscription; disabling shared storage keys breaking the provider's *own*
  data-plane polling; and Entra RBAC not having propagated before a secret write.
- **Running a workload caught the rest.** The chart's node selector matched no
  node on a single-pool cluster; and image pulls failed 401 because the kubelet
  identity had no AcrPull — which the cluster module *cannot* grant, since the
  registry is created after the cluster, so the assignment belongs to the module
  that owns the registry.

The conclusion I would offer: validate checks syntax, plan checks the graph,
apply checks the provider, and only running a workload checks that the platform
is usable. A pipeline that stops at `validate` is testing almost nothing.

**"Why is `count` on a computed value such a common mistake?"**

Because `count = var.some_id == "" ? 0 : 1` reads as obviously correct, and it
*is* correct when the id is a literal. It only fails when the id comes from a
resource in the same apply — which is exactly how composed modules are wired.
The fix is to gate on a plain boolean that is known before the graph is walked,
and to accept slightly more verbose module inputs in exchange.

**"How do you handle Terraform state?"**

Azure Blob with versioning, a 90-day delete-retention window, a delete lock,
default-deny network rules and **no shared account keys** — the pipeline
authenticates with its OIDC identity through RBAC. State is the most sensitive
artifact the platform produces: every resource id and any value Terraform had to
read.

The sandbox deliberately uses local state, because bootstrapping a remote
backend for a disposable environment costs more than the environment tracks.

**"The pipeline identity has Owner. Isn't that too much?"**

Yes, and it is a documented trade-off rather than an oversight. Terraform creates
role assignments — workload identity, AcrPull, Key Vault RBAC — and Contributor
cannot do that. The mitigations: the identity is only assumable from this
repository, only from a protected environment, and an ABAC condition prevents it
granting Owner to anything else.

---

## 8. Questions to expect about the gaps

Do not wait to be asked. Offer these.

**"What is not finished?"**

The .NET 10 service is written but never compiled — no SDK in the build
environment — so what actually runs on the cluster is a Python service against
the same chart and identity wiring. The OTel Collector, KEDA, Kyverno and the
Azure DevOps pipeline are all coded and unapplied. No trace has been observed
arriving in Application Insights. The autoscaler tuning is reasoned, not
load-tested. All of it is in [COVERAGE.md](COVERAGE.md), split three ways.

**"Why did you deploy to a 4 vCPU subscription at all?"**

Because it was the subscription available, and applying to a constrained
environment is more informative than not applying at all. It forced the modules
to become genuinely parameterised — node pools, zones, disk types, egress mode,
SKUs and diagnostics all became inputs rather than assumptions — and that work
benefits every environment.

It also produced a useful number: **AKS system components alone request roughly
1.8 of 2 vCPU on a B2s_v2**. Two nodes are needed before any workload fits. That
is not in the documentation anywhere.

**"What would you do differently?"**

Deploy earlier. Everything validated, scanned and reviewed cleanly for a long
time while containing nine defects. The gap between "the code is correct" and
"the system works" was larger than I would have guessed, and the only thing that
closed it was applying.

---

## One-line answers, for when time is short

| Question | Answer |
|---|---|
| Biggest security decision | Removing every long-lived credential via OIDC federation, pinned per claim |
| Biggest cost decision | Splitting log stores by purpose — ~€950/month, no diagnostic loss |
| Biggest reliability decision | Asymmetric autoscaling: fast up, slow down |
| Biggest delivery decision | The pipeline proposes, Argo CD deploys |
| Most surprising finding | AKS addons need most of a 2 vCPU node before any workload fits |
| Best bug found | The CVSS gate blocked HIGH findings that policy said should only warn |
| Biggest gap | The .NET service is written but never built |
| What proves it works | Three controls refused me during verification |
