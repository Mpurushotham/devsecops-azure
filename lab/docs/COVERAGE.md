# Coverage against the role — what is proven, coded, or absent

Three honest categories, because "we have Terraform for it" and "it is running"
are not the same claim:

| | Meaning |
|---|---|
| **Proven** | Deployed to live Azure and verified by observing it work |
| **Coded** | Written, validated, scanned, reviewed — never executed |
| **Absent** | Not built. Named here so the gap is visible, not discovered |

GCP is excluded by instruction; the platform is Azure-only.

---

## Areas of ownership

### 1. Cloud infrastructure with Terraform — networking, IAM, AKS, node pools, autoscaling

**Proven.** 61 resources applied to a live subscription. AKS 1.34.9 with Azure
CNI Overlay + Cilium, workload identity, local accounts disabled, Entra RBAC.
Four-subnet segmentation with deny-by-default NSGs. The cluster autoscaler was
observed scaling 1 → 2 nodes when pods went `Pending`, then the HPA reading real
CPU/memory metrics off the workload.

Node pool topology (system / app / spot / Windows) is **coded** — a 4 vCPU
quota admits one pool, so only the single-pool path ran. The multi-pool path is
exercised by `terraform validate` and the plan graph, not by an apply.

### 2. CI/CD with GitHub Actions and Azure DevOps

**GitHub Actions: proven.** 23 checks passing, 0 failing on the open PR:
lint, tests, SAST (Semgrep, Bandit), SCA, secret scanning (gitleaks,
TruffleHog), SBOM, licence policy, IaC scan, Helm contract assertions.
A reusable build/sign workflow and a Terraform plan/apply workflow.

**Azure DevOps: wired, blocked on an account grant.** The pipeline exists in
`ADODemotests/DevOps-Demo`, compiles cleanly, and resolves a **workload identity
federation** service connection — no client secret, the same model as the GitHub
OIDC path. Sandbox state was migrated to Azure Blob so a pipeline can operate it.

It has not produced a green run: new ADO organisations no longer receive the
free hosted-agent grant, so jobs are scheduled and then fail with *"No hosted
parallelism has been purchased or granted"*. That is an account-level grant, not
a defect — and the run history shows it: the first attempt failed YAML
*validation*, the second compiled and failed only at agent allocation.
Unblocking is a form (2–3 days) or a self-hosted agent. See
[AZURE-DEVOPS.md](AZURE-DEVOPS.md).

### 3. GitOps across dev, staging, production

**Proven.** Argo CD installed on the live cluster, an `Application` pointed at
this repository, reconciled to `Synced/Healthy` from git.

Two behaviours verified rather than assumed:

- **Self-heal.** Deleting the Deployment out from under Argo CD had it restored
  within ~25 seconds.
- **Git as the only write path.** A NetworkPolicy change was made by editing the
  Application's values; Argo CD reconciled it. Nothing was applied to the
  cluster by hand.

The app-of-apps root, `AppProject` tenancy boundaries and per-environment
overlays are **coded**; only the single sandbox Application was applied.

### 4. Observability — Elastic/Kibana, Datadog, Application Insights, tracing

**Split, and this is the weakest area.**

| Component | State |
|---|---|
| Log Analytics workspace, capped ingestion | **Proven** — deployed, diagnostics flowing from AKS, Key Vault, ACR |
| Application Insights | **Proven** — resource deployed, connection string written to Key Vault |
| Managed Prometheus workspace + DCR | **Proven** — deployed and associated with the cluster |
| Kubernetes metrics → HPA | **Proven** — HPA reading live CPU/memory |
| SLO burn-rate alerts, action groups | **Coded** — disabled in sandbox by design |
| OTel Collector (tail sampling, PII scrubbing) | **Coded** — config written, never deployed |
| Elastic / Kibana | **Coded** — collector exporter + Key Vault secret path only |
| Datadog | **Coded** — Key Vault secret path only |
| Managed Grafana | **Coded** — disabled in sandbox (~€45/month) |
| Distributed tracing end to end | **Absent as a demonstration** — no trace has been observed traversing services |

Honest summary: the *plumbing* is provisioned and the *policy* is written, but
no trace or log has been watched arriving in a backend. That is the gap I would
close first.

### 5. Reliability and scale — AKS workloads, HPA, RabbitMQ, SQL Server

- **HPA: proven.** Live, reading real metrics, `cpu: 6%/70% memory: 75%/80%`.
- **Cluster autoscaler: proven.** Observed scaling on pending pods.
- **RabbitMQ: proven.** 4.1.8 running, `payments-settlement` queue declared,
  reachable over AMQP from the payments namespace. Single node with an
  `emptyDir` — a sandbox topology, not production, which wants the Cluster
  Operator with a 3-node quorum and persistent volumes.
- **KEDA: coded.** The chart emits a `ScaledObject` and a RabbitMQ trigger
  example; the operator is not installed. This is the one place the "scale on
  queue depth, not CPU" argument is asserted rather than demonstrated.
- **SQL Server: coded.** Entra-only auth, private endpoint, CMK TDE, LTR
  backups, threat detection — all written and plan-clean, `enable_sql = false`
  in the sandbox because it is the largest avoidable cost.
- **Seasonal spike handling: coded.** Asymmetric autoscaler tuning, surge-only
  rollouts, PDBs, zone spread. Reasoned through in
  [ADR-007](DECISIONS.md#adr-007); never load-tested.

### 6. Secure environments — Key Vault, IAM/RBAC, network segmentation

**Proven**, and verified on the running pod rather than in the plan:

```
image digest-pinned          runAsNonRoot (uid 64198)     read-only rootfs
no privilege escalation      all capabilities dropped     seccomp RuntimeDefault
SA token not automounted     workload identity injected   Pod Security: restricted
Key Vault ACL default-deny   storage: no shared keys      ACR admin disabled
API server IP-restricted     NetworkPolicy default-deny
```

Three controls proved themselves by **refusing legitimate-looking work**, which
is the only way to know a control is live rather than declared:

1. Pod Security `restricted` rejected a debug pod missing capability drops.
2. The namespace default-deny NetworkPolicy blocked DNS for an ad-hoc pod.
3. The workload's own NetworkPolicy blocked AMQP until an explicit allow rule
   was added through git — denied, then reviewed, then reachable.

**Coded, not proven:** Kyverno admission policies (Pod Security covers the same
ground here), private endpoints, Defender for Containers, Falco.

### 7. Secure handling of payment-related traffic

**Coded.** The controls exist and are reasoned about: NAT gateway for a static
allowlistable egress IP ([ADR-003](DECISIONS.md#adr-003)), data-subnet egress
denial, PII scrubbing at the collector, 100% trace sampling on payment routes,
Key Vault CSI for processor credentials, Entra-only database auth.

In the sandbox the NAT gateway is **disabled** (~€32/month), so egress uses
ephemeral load-balancer addresses and is *not* allowlistable. That is the one
payment-specific control the sandbox cannot demonstrate.

### 8. Migrating .NET Framework VMs to containerised .NET 10 on AKS

**Coded, and this is the second real gap.**

`lab/apps/payments-api` is a .NET 10 minimal API demonstrating the platform
contract — workload identity with no connection string, OTel, split
liveness/readiness, graceful drain, chiseled runtime image with no shell.
`docs/MIGRATION-DOTNET.md` sets out the containerise-on-Windows-first
sequencing, phase gates, the Kyverno exception Windows containers need, and the
tracking metric that ends with the node pool deleted.

**It has never been compiled or deployed.** No .NET SDK was available in this
environment, so the workload actually running on the cluster is the repository's
existing Python service. The chart, the identity wiring and the security
contract are all exercised — but by a different runtime than the one claimed.
A reviewer should read the .NET code as a design artifact, not as tested
software.

The Windows node pool is likewise coded and unapplied: no vCPU quota for it.

### 9. Collaboration and DevOps culture

**Coded**, in the sense that documentation is the artifact:
17 ADRs recording what was chosen, what it costs and what would justify
revisiting it; runbooks written for someone paged at 03:00; a migration plan
with gates and an owner-tracking metric; a `Makefile` where every CI check runs
locally with the same command.

---

## Requirements checklist

| Requirement | State |
|---|---|
| Azure: AKS, ACR, Key Vault, networking, identity | **Proven** |
| Kubernetes, orchestration, Helm | **Proven** — chart deployed twice, once by hand and once by Argo CD |
| IaC with Terraform | **Proven** — 5 modules, 4 environments, applied |
| CI/CD: GitHub Actions | **Proven** |
| CI/CD: Azure DevOps | **Wired** — compiles, federated connection resolves; blocked on hosted parallelism |
| Observability: logging, metrics, alerting | **Partly proven** — see §4 |
| Observability: distributed tracing | **Coded** |
| Incident management | **Coded** — runbooks, no incident rehearsed |
| Linux, networking, cloud security | **Proven** |
| Windows Server | **Coded** — node pool, no quota to apply it |
| Modern .NET | **Coded** — written, never built |

---

## If I had one more day

In priority order, because each closes a claim that is currently asserted rather
than shown:

1. **Build and deploy the .NET 10 service.** It is the named advantage in the
   role and the one place the running system differs from the documented one.
2. **Deploy the OTel Collector and watch a trace arrive** in Application
   Insights. That converts the entire observability section from plumbing to
   evidence.
3. **Install KEDA and drive the RabbitMQ queue** until it scales. The queue and
   the trigger config both exist; only the operator is missing.
4. **Get an agent for the Azure DevOps pipeline** — the form, or a self-hosted
   agent. Everything else on that side is done.
5. **Load-test the seasonal-spike path** — the autoscaler tuning in ADR-007 is
   reasoned, not measured.

None of these are blocked by design. Items 1–3 are blocked by the 4 vCPU quota
and a missing SDK; items 4–5 by tooling that is not attached to this
subscription.
