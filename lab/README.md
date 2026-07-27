# Platform Lab — Azure

A complete, automated Azure platform build: Terraform for the infrastructure,
GitOps for delivery, a reference .NET 10 workload, and the observability and
security controls that make it operable.

Built to the shape of a Senior Platform Engineer brief — cloud infrastructure,
AKS, CI/CD, observability, reliability at seasonal scale, secure handling of
payment traffic, and a route off legacy .NET Framework VMs.

It is **self-contained** and sits alongside the existing DevSecOps solution in
this repository. That solution's security gates, Kyverno policies and Semgrep
rules are reused rather than forked; nothing here modifies it.

---

## What is here

| Area | Where | What it does |
|---|---|---|
| Infrastructure | `terraform/` | VNet segmentation, AKS, ACR, Key Vault, SQL, observability, across dev/staging/prod |
| Delivery | `../.github/workflows/lab-*.yml`, `azure-pipelines/` | Reusable build/sign workflow, Terraform plan+apply, GitOps promotion — mirrored on both CI platforms |
| Deployment | `kubernetes/` | ArgoCD app-of-apps, projects as tenancy boundaries, namespaces with PSA and quotas |
| Workload contract | `charts/dotnet-service/` | One chart encoding non-root, digest pinning, PDB, network policy, HPA/KEDA, Key Vault CSI |
| Reference app | `apps/payments-api/` | .NET 10 minimal API: workload identity, OTel, split probes, graceful drain |
| Automation | `Makefile`, `scripts/` | Every CI check, runnable locally with the same command |
| Documentation | `docs/` | Architecture, decisions with costs, runbooks, migration plan |

---

## Documentation

| Document | Read it for |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Diagrams: platform, network, identity, delivery, autoscaling, observability |
| [DECISIONS.md](docs/DECISIONS.md) | 17 ADRs — what was chosen, what it costs, what would change it |
| [RUNBOOKS.md](docs/RUNBOOKS.md) | Incident response, written for 03:00 |
| [MIGRATION-DOTNET.md](docs/MIGRATION-DOTNET.md) | Legacy .NET Framework VMs → containerised .NET 10 on AKS |
| [SANDBOX.md](docs/SANDBOX.md) | Deploying to a real, quota-constrained subscription |

---

## The three ideas worth knowing

**1. No long-lived credentials exist.** GitHub Actions, Azure DevOps and pods
all federate into Entra ID over OIDC. There is no ACR password, no service
principal secret, no SQL password. Each federated credential is pinned to one
claim — repository + environment, or namespace + service account — so a
compromised staging pod cannot obtain a production token.
([ADR-004](docs/DECISIONS.md#adr-004))

**2. The pipeline never deploys.** CI builds and signs an image, then commits a
digest change (dev) or opens a PR (staging, prod). ArgoCD reconciles. A
compromised pipeline can propose a change, not make one — and rollback is `git
revert`, the same mechanism as the forward path, so it is exercised constantly
rather than being an untested emergency procedure.
([ADR-014](docs/DECISIONS.md#adr-014))

**3. Guardrails are enforced in three places.** The Helm chart sets the secure
values, `helm template` output is asserted against 17 contract checks in CI, and
Kyverno rejects violations at admission. A service team supplies an image and a
few values; being non-root with dropped capabilities, resource requests, a
disruption budget and a network policy is not something they can forget.

---

## Prerequisites

```bash
terraform >= 1.9    tflint      trivy      helm >= 3.16
kubectl             az CLI      docker     python3
```

```bash
brew install terraform terraform-linters/tap/tflint trivy helm kubectl azure-cli
```

---

## Getting started

### 1. Bootstrap (once per subscription)

Creates the remote state account — versioned, delete-locked, no account keys,
default-deny network rules — and the OIDC federation the pipelines use.

```bash
cd lab
make bootstrap

# Move the bootstrap's own state into the backend it just created
cd terraform/bootstrap && terraform init -migrate-state
```

### 2. Configure an environment

```bash
cd lab
make backend-config ENV=dev          # generates backend.hcl from bootstrap outputs
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
$EDITOR terraform/envs/dev/terraform.tfvars
```

`terraform.tfvars` and `backend.hcl` are gitignored. Secrets belong in the
pipeline's secret store or Key Vault, passed as `TF_VAR_*` — never in a file.

### 3. Plan and apply

```bash
make check                  # everything CI runs — do this before applying
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
```

### 4. Bootstrap the cluster

```bash
make kubeconfig ENV=dev
make argocd-bootstrap       # applies the root Application; git converges the rest
```

---

## Everyday commands

```bash
make help                   # list targets
make check                  # fmt, lint, validate, IaC scan, chart tests
make plan ENV=staging
make output ENV=prod
make chart-policy           # assert the security contract on rendered manifests
make app-build && make app-scan
make destroy ENV=dev        # blocked for prod, deliberately

# Sandbox on a real subscription
make sandbox-quota          # check vCPU headroom before spending time
make sandbox-tfvars         # generate tfvars from the current az login
make sandbox-cost           # month-to-date spend
```

Every one of these runs in CI too. A check that exists only in the pipeline gets
discovered at PR time; one that exists only locally gets skipped. Both run the
same targets.

---

## Environment shapes

Same architecture in all four; capacity and exposure differ, and every
difference is deliberate. `sandbox` is the shape that fits a free-tier
subscription's 4 vCPU quota — see [SANDBOX.md](docs/SANDBOX.md).

| | sandbox | dev | staging | prod |
|---|---|---|---|---|
| API server | Public, CIDR-restricted | Public, CIDR-restricted | Public, CIDR-restricted | **Private** |
| Zones | none | 1 | 1 | 3 |
| Nodes | 1–2 × B2s (single pool) | 1–8 × D4 | 2–8 × D4 | 5–30 × D8 |
| Spot pool | — | — | — | Yes (batch) |
| Windows pool | — | — | — | Yes (migration) |
| SQL | off by default | GP serverless (auto-pause) | GP serverless | **BC_Gen5_8**, zone-redundant, read-scale |
| Private endpoints | — | — | — | SQL, Key Vault, ACR, Blob |
| Log retention | 30d, 0.5GB/day cap | 30d, 2GB/day cap | 30d, 5GB/day cap | 180d, uncapped |
| Alerting | None | None | Tickets only | Pages on-call |
| Promotion | Manual | Auto-commit | PR + review | PR + review + environment approval |

Dev and staging keep public API endpoints because the alternative — a
self-hosted runner fleet per environment — costs more than it protects for
environments with no customer data. They are still restricted to explicit CIDRs,
enforced by a required Terraform variable, a validation rule and a plan-time
precondition, so a cluster that is both public and unrestricted cannot be
applied. ([ADR-006](docs/DECISIONS.md#adr-006))

---

## Verification status

Everything in this lab has been checked locally, not just written:

| Check | Result |
|---|---|
| `terraform validate` — 5 modules, 4 envs, bootstrap | Pass |
| `terraform fmt -check -recursive` | Pass |
| `tflint` — all modules and environments | Pass, 0 issues |
| `trivy config` — all environments | 0 CRITICAL / 0 HIGH |
| `helm lint` + `helm template` | Pass, 9 manifests |
| Security contract assertions on rendered output | 17/17 pass |
| `trivy image` on the reference app | 0 CRITICAL / 0 HIGH |
| Container starts under a read-only rootfs as uid 10001 | Pass, no errors logged |
| **`terraform plan` against a live subscription** (`sandbox`) | **Pass — 58 resources, 0 destroy** |
| Security controls asserted on that plan | 19/19 preserved |

The one Trivy exception is recorded in `.trivyignore.yaml` with a justification
and an expiry date, because a suppression without a review date becomes a
permanently accepted vulnerability that nobody remembers accepting.

---

## What this lab does not do

Stated plainly, so the gaps are visible rather than discovered:

- **Only `sandbox` has been planned against a real subscription.** The plan
  succeeds and creates 58 resources; dev/staging/prod remain unapplied, and
  their costs are estimates. See [SANDBOX.md](docs/SANDBOX.md) — that exercise
  found a `count`-on-computed-value defect affecting all four environments that
  `terraform validate` could not catch.
- **RabbitMQ is referenced, not provisioned.** KEDA triggers and network policy
  ports are in place; the cluster itself would be installed via the RabbitMQ
  Cluster Operator in a follow-up.
- **The .NET app is a reference, not a product.** It demonstrates the platform
  contract and has no meaningful business logic or test suite of its own.
- **Disaster recovery is single-region.** Multi-zone within the region, with
  geo-redundant backups; a documented cross-region recovery plan is the next
  piece of work. ([ADR-012](docs/DECISIONS.md#adr-012))
