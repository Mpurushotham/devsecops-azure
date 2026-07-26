# Architecture Decision Records

Each record states the decision, what it costs, what it buys, and what would
make us revisit it. The last part matters most: a decision without a trigger
for revisiting is a decision nobody can safely change later.

Costs are illustrative monthly figures for a mid-sized production footprint,
used to make trade-offs concrete. Validate against the Azure pricing calculator
for your actual region and reservation position before quoting them.

| ADR | Decision | Status |
|---|---|---|
| [001](#adr-001) | Azure CNI Overlay + Cilium | Accepted |
| [002](#adr-002) | Subnet segmentation by trust level | Accepted |
| [003](#adr-003) | NAT gateway for static egress | Accepted |
| [004](#adr-004) | Workload identity everywhere, no stored secrets | Accepted |
| [005](#adr-005) | Four node pools by workload class | Accepted |
| [006](#adr-006) | Private API server + self-hosted runners in prod | Accepted |
| [007](#adr-007) | Autoscaler tuned asymmetrically | Accepted |
| [008](#adr-008) | Entra-only SQL authentication | Accepted |
| [009](#adr-009) | Business Critical SQL in production | Accepted |
| [010](#adr-010) | Split log stores: Log Analytics + Elastic | Accepted |
| [011](#adr-011) | Alert on symptoms, not causes | Accepted |
| [012](#adr-012) | Azure-only; no second cloud | Accepted |
| [013](#adr-013) | Windows node pool as a migration waypoint | Accepted |
| [014](#adr-014) | GitOps: the pipeline never deploys | Accepted |
| [015](#adr-015) | OTel Collector as the only telemetry egress | Accepted |
| [016](#adr-016) | Maintain GitHub Actions and Azure DevOps in parity | Accepted |
| [017](#adr-017) | CVSS gate reads the score, not the SARIF level | Accepted |

---

## ADR-001 — Azure CNI Overlay with Cilium data plane {#adr-001}

**Decision.** Pods get IPs from an overlay CIDR (`192.168.0.0/16`), not from the
VNet. Network policy is enforced by Cilium in eBPF.

**Alternatives.**

| Option | Pod IP source | Consequence |
|---|---|---|
| Kubenet | Overlay, UDR-based | Deprecated; poor scale, no NetworkPolicy |
| Azure CNI (classic) | VNet | Every pod consumes a VNet IP |
| **Azure CNI Overlay + Cilium** | Overlay | VNet sized for nodes only |
| Istio / sidecar mesh | Either | Full L7 control, ~100m CPU + 100MB per pod |

**Why.** With classic CNI, 30 nodes × 110 pods needs ~3,300 VNet addresses — a
/20 per environment, before growth. Overlay decouples pod density from address
planning entirely, so a seasonal scale-out cannot exhaust the subnet.

Cilium gives eBPF NetworkPolicy with no sidecar. At 200 pods, a sidecar mesh
would add roughly 20 vCPU and 20GB of memory — about €1,400/month of compute
spent on proxies rather than on serving traffic.

**Cost of the decision.** No L7 policy or mTLS between services. Accepted
because TLS terminates at the ingress with ModSecurity in front, and the
east-west threat model is addressed by default-deny NetworkPolicies.

**Revisit if.** Per-service mTLS becomes a compliance requirement, or L7
authorization (method- and path-level) is needed between internal services.
Cilium Service Mesh is then the first thing to evaluate, since it is already
the data plane.

---

## ADR-002 — Subnet segmentation by trust level {#adr-002}

**Decision.** Four subnets — ingress, system, apps, data — each with a
deny-by-default NSG. Private endpoints live in `data` and are denied all
outbound internet access.

**Why.** Segmentation is what converts a single compromised component into a
contained incident. The data subnet rule is the load-bearing one: a private
endpoint never legitimately originates a connection, so denying its egress
turns a stolen database credential from an exfiltration path into a dead end.

**Cost.** More NSG rules to maintain, and a genuinely new integration requires
a reviewed rule change rather than working by default. That review is the
point.

**Revisit if.** The rule count becomes unmanageable — at which point Azure
Firewall with FQDN-based rules replaces per-NSG maintenance.

---

## ADR-003 — NAT gateway for deterministic egress {#adr-003}

**Decision.** All cluster egress goes through a NAT gateway with a static,
zone-redundant public IP.

**Why.** Payment processors and telecom partners allowlist source IPs. Default
AKS egress uses load-balancer outbound addresses that can change when the
cluster scales — meaning the integration would break precisely during a traffic
spike, when scaling happens. A static IP is a hard requirement of the business
integration, not a preference.

**Cost.** ~€35/month plus data processing. Negligible against one failed
settlement window.

**Revisit if.** Partners move to mTLS or signed-request authentication and drop
IP allowlisting.

---

## ADR-004 — Workload identity everywhere {#adr-004}

**Decision.** No long-lived credential exists in the delivery path. GitHub
Actions, Azure DevOps and pods all federate into Entra ID via OIDC. AKS local
accounts and the ACR admin user are disabled.

**Why.** A leaked service principal password grants standing access until
someone notices and rotates it. A federated token lives about an hour and is
bound to a claim — repository, environment, or namespace + service account —
that an attacker outside that context cannot reproduce.

The subject-claim pinning is what makes it more than cosmetic: the `prod`
identity is only assumable by `system:serviceaccount:payments:payments-api` on
the production cluster. A compromised staging pod gets an authentication
failure, not a production token.

**Cost.** Federated credentials must be created before the workload that uses
them, which makes the Terraform dependency graph less flexible. Local
development needs `az login` rather than a connection string in `.env`.

**Revisit if.** A component genuinely cannot support OIDC — in which case the
credential goes in Key Vault with a documented rotation schedule and a
justification, never in a pipeline variable.

---

## ADR-005 — Four node pools by workload class {#adr-005}

**Decision.** `system` (tainted, platform only), `apps` (general), `spot`
(interruptible batch), `win` (legacy .NET Framework).

**Why.** A single pool means a runaway batch job can starve the API of CPU on
the same node, and platform components compete with workloads under pressure.

Spot pricing is roughly 70% below on-demand. For reconciliation and reporting —
work that tolerates eviction and re-run — that is real money: ~€800/month of
batch compute becomes ~€240.

**Cost.** More pools to patch and upgrade; workloads need correct tolerations
and node selectors. The chart sets these by default, so service teams do not
have to know.

**Revisit if.** The Windows pool empties (see [ADR-013](#adr-013)) — delete it
then, since Windows nodes are the most expensive per-core in the cluster.

---

## ADR-006 — Private API server in production {#adr-006}

**Decision.** Production runs a private cluster. Dev and staging keep a public
endpoint restricted to explicit CIDRs.

**Why.** The API server is the single highest-value target: whoever reaches it
with a valid token controls every workload. Removing it from the internet
removes an entire class of attack, including credential stuffing against Entra
and exploitation of a future API-server CVE before the patch window.

**Cost.** Real, and worth stating plainly. GitHub-hosted runners cannot reach a
private endpoint, so production deployment needs self-hosted runners in the
VNet — roughly €150/month plus the operational burden of maintaining them.
Break-glass access needs a bastion or Azure Bastion session.

This is why non-production stays public: paying that cost three times over to
protect environments with no customer data would be poor judgement. The
mitigation there is CIDR restriction, enforced by a required Terraform variable
with a validation rule, so a public *and* unrestricted cluster cannot be
applied by accident.

**Revisit if.** GitHub adds native private networking that removes the runner
fleet requirement.

---

## ADR-007 — Asymmetric autoscaler tuning {#adr-007}

**Decision.** Scale up immediately and aggressively; scale down slowly.

```
scaleUp:   stabilization 0s,   +100% or +4 pods per 30s
scaleDown: stabilization 300s, −25% per 60s
cluster autoscaler: scale_down_delay_after_add = 15m
```

**Why.** The two failure modes are not symmetric. Scaling up late means dropped
traffic during a seasonal peak — lost revenue and a customer-visible incident.
Scaling down late means paying for idle nodes for a few extra minutes.

At €0.30/node/hour, an extra 10 nodes for 15 minutes costs about €0.75. One
minute of dropped calls during a peak costs materially more, and cannot be
recovered.

**Cost.** Slightly higher steady-state spend after a spike. Deliberate.

**Revisit if.** Traffic patterns become predictable enough for scheduled
scaling, which would beat reactive scaling on both cost and latency.

---

## ADR-008 — Entra-only SQL authentication {#adr-008}

**Decision.** `azuread_authentication_only = true`. No SQL login exists, so
there is no password in any connection string.

**Why.** SQL logins cannot be centrally revoked, do not expire, and end up in
configuration files, screenshots and support tickets. Removing them eliminates
the "leaked connection string" incident class entirely rather than mitigating
it.

**Cost.** Tooling that only speaks SQL auth stops working. Local development
requires `az login`. Schema migrations need `CREATE USER FROM EXTERNAL
PROVIDER`, run by a job with the right identity.

**Revisit if.** A vendor tool with no Entra support becomes business-critical —
and then only with a compensating control, not by re-enabling SQL auth broadly.

---

## ADR-009 — Business Critical SQL in production {#adr-009}

**Decision.** `BC_Gen5_8`, zone-redundant, read-scale enabled. Non-production
uses serverless General Purpose that auto-pauses.

| Tier | Storage | Failover | ~Cost/month | p99 read |
|---|---|---|---|---|
| GP_S_Gen5_2 (serverless) | Remote | 30–60s | ~€200 (auto-pause) | ~15ms |
| GP_Gen5_8 | Remote | 30–60s | ~€1,100 | ~10ms |
| **BC_Gen5_8** | Local SSD | <10s | ~€2,900 | ~2ms |

**Why.** The premium buys three things: local SSD (a ~5x latency improvement
that shows up directly in API p99), a free read replica that takes reporting
load off the primary during peaks, and sub-10-second failover.

**Cost.** ~€1,800/month more than General Purpose. Justified by the read
replica alone — the alternative is provisioning a second GP database for
reporting, which costs more and adds replication lag to reason about.

Non-production auto-pauses after an hour idle, so dev and staging cost close to
nothing overnight and at weekends.

**Revisit if.** Read replica utilisation stays below ~20%, in which case
General Purpose plus a scheduled export to analytics is cheaper.

---

## ADR-010 — Split log stores {#adr-010}

**Decision.** Platform and audit logs to Log Analytics; application logs to
Elastic; traces to App Insights; metrics to managed Prometheus.

**Why.** The two log workloads have opposite requirements.

| | Log Analytics | Elastic |
|---|---|---|
| Purpose | Audit evidence | Engineer debugging |
| Retention | 180 days, immutable | 14–30 days |
| Query | KQL, occasional | Full-text, constant |
| ~Cost/GB | €2.30 | €0.40 |
| Volume | Low (control plane) | High (application) |

Sending everything to both roughly doubles the observability bill for no
diagnostic gain: nobody greps audit logs during an incident, and nobody
produces compliance evidence from a 14-day Elastic index.

At ~500GB/month of application logs, routing them to Elastic instead of Log
Analytics saves roughly €950/month.

**Cost.** Two systems to operate, and engineers must know which to search.
Mitigated by Grafana as a single query surface over both.

**Revisit if.** Elastic operational overhead exceeds the saving, or Log
Analytics Basic Logs tier closes the price gap.

---

## ADR-011 — Alert on symptoms, not causes {#adr-011}

**Decision.** Pages fire on multi-window SLO error-budget burn. CPU, memory and
pod restarts are dashboards, never pages.

**Why.** Cause-based alerts have a poor signal-to-noise ratio: a service at 90%
CPU meeting its latency objective is correctly sized, and paging for it teaches
people to ignore alerts. Multi-window burn rate fires only when users are
actually affected.

```
Fast burn: 14.4x budget over 1h  → page   (budget gone in ~2 days)
Slow burn: 6x budget over 6h     → ticket (degrading, not urgent)
```

**Cost.** A slowly developing problem that has not yet consumed budget may go
unpaged for longer. That is the intended trade: the ticket path catches it.

**Revisit if.** Post-incident reviews show repeated cases where a cause-based
alert would have given useful lead time.

---

## ADR-012 — Azure only {#adr-012}

**Decision.** One cloud. No second-cloud footprint for redundancy or
negotiation leverage.

**Why.** Multi-cloud doubles the operational surface for every platform change:
two IAM models, two networking stacks, two sets of Terraform providers, two
on-call runbooks. For a team of this size that cost is paid continuously, while
the benefit — surviving a full regional Azure outage — is addressed more cheaply
by multi-zone deployment plus a documented cross-region recovery plan.

**Cost.** Concentration risk with one vendor, and less commercial leverage. Both
accepted, explicitly, rather than by default.

**Revisit if.** A regulator requires cross-provider redundancy, or a specific
managed service (typically analytics or ML) is materially better elsewhere. In
that case the boundary should be a whole workload with a clean interface, never
a shared control plane.

---

## ADR-013 — Windows node pool as a waypoint {#adr-013}

**Decision.** A Windows node pool exists so .NET Framework services can leave
their VMs before they are ported to .NET 10. It is explicitly temporary.

**Why.** The alternative sequencing — port to .NET 10 first, then containerise —
means the legacy service stays on unmanaged VMs for the whole porting effort,
with a separate deployment path, separate monitoring and separate patching.

Moving to Windows containers first gets the service onto the platform's
scheduler, observability and secret management immediately, and turns the port
into an incremental change rather than a big-bang migration.

**Cost.** Windows nodes are roughly twice the per-core price of Linux, images
are ~5GB against ~300MB, and node startup takes minutes rather than seconds.
Real money, spent deliberately for a bounded period.

**Revisit.** Not "if" — this pool is expected to be deleted. Track the count of
workloads on it as a migration metric; when it reaches zero, remove the pool.
See [MIGRATION-DOTNET.md](./MIGRATION-DOTNET.md).

---

## ADR-014 — GitOps: the pipeline never deploys {#adr-014}

**Decision.** CI builds and signs an image, then commits or proposes a digest
change in git. ArgoCD reconciles. The pipeline holds no cluster credentials.

**Why.** Three consequences, in order of importance:

1. **Blast radius.** A compromised pipeline can propose a change; it cannot make
   one. Production changes require a merge, which requires review.
2. **Rollback.** `git revert` — the same mechanism as the forward path, so it is
   exercised constantly rather than being an untested emergency procedure.
3. **Drift.** ArgoCD self-heals, so the cluster provably matches git. "What is
   running?" is answered by reading a file, not by querying a cluster.

**Cost.** Deployment is asynchronous, so the pipeline must poll for rollout
status. Self-heal reverts manual `kubectl` edits, which is painful the first
time someone hotfixes by hand — and is exactly the property that makes the
cluster trustworthy during an incident review.

**Revisit if.** A workload genuinely needs imperative orchestration (a
multi-step data migration, for example). Even then, prefer a Job in git over
pipeline-driven `kubectl`.

---

## ADR-015 — OTel Collector as the only telemetry egress {#adr-015}

**Decision.** Services speak OTLP to an in-cluster collector and nothing else.
Sampling, scrubbing and routing are collector configuration.

**Why.** Sampling policy and PII scrubbing become platform concerns rather than
per-service ones. Changing observability vendor is a collector config change,
not a redeploy of every service. A service that logs too much is contained by
configuration rather than by a code change in someone else's repository.

Tail sampling is the substantive part: head sampling at 10% discards 90% of
errors. The collector keeps 100% of errors, 100% of requests slower than 1s and
100% of payment flows, sampling the rest at 5% — roughly a 70% cost reduction
with no loss of diagnostic value.

**Cost.** The collector is a critical path component and needs its own
capacity, HA and monitoring. `memory_limiter` is first in every pipeline so it
sheds data rather than OOM-killing the node.

**Revisit if.** Collector operational cost approaches the backend savings.

---

## ADR-016 — GitHub Actions and Azure DevOps in parity {#adr-016}

**Decision.** Both platforms are supported, with pipelines that mirror each
other step for step: same Terraform version, same gates, same CVSS policy.

**Why.** The organisation uses both. Letting them diverge means a service's
security posture depends on which CI system its team happened to pick — which
is indefensible during an audit and invisible day to day.

**Cost.** Two implementations to keep in sync. Mitigated by keeping the logic in
scripts (`.github/scripts/cvss_gate.py`, `lab/scripts/`) that both call, so only
the orchestration differs.

**Revisit.** Consolidate onto one platform when the organisation is ready. This
ADR describes an interim state, and saying so is better than pretending the
duplication is a design goal.

---

## ADR-017 — The CVSS gate reads the score, not the SARIF level {#adr-017}

**Decision.** `.github/scripts/cvss_gate.py` reads
`properties.security-severity` from the SARIF rule and applies the documented
thresholds. Falls back to the SARIF level only for scanners that publish no
score.

**Why.** The original gates used SARIF `level` as a severity proxy. Trivy maps
**both** CRITICAL and HIGH to `level: "error"`, so the implementation blocked
builds on HIGH findings that policy says should only warn, and reported MEDIUM
as HIGH. The policy is written in CVSS scores, so the gate should read CVSS
scores.

The practical damage of the old behaviour was worse than a mis-labelled log
line: a gate that blocks on findings the policy accepts trains people to bypass
it, which is how the CRITICAL that matters gets waved through.

**Cost.** One more script in the CI path, and scanners without
`security-severity` still fall back to level-based classification.

**Revisit if.** A scanner emits scores in a different SARIF property; extend
`score_for()` rather than reintroducing per-workflow logic.
