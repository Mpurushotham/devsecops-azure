# Sandbox — deploying to a real, quota-constrained subscription

The `sandbox` environment exists to prove the modules actually apply against
live Azure, on an account with a small vCPU quota and a real bill. It runs the
same module set as dev/staging/prod, so what gets exercised is the production
code path — only the sizing and the cost-bearing options differ.

---

## What the subscription allows

Measured on the target subscription, not assumed:

| | |
|---|---|
| Agreement | Microsoft Customer Agreement — **charges are real**, not a capped trial |
| Region | swedencentral |
| **Total regional vCPU quota** | **4** |
| Per-family vCPU quota | 4 (D, B, E, F families all capped at 4) |
| Role | Owner on the subscription — required, since the modules create role assignments |

**The 4 vCPU quota is the binding constraint** and it dictates the topology.
For comparison, `dev` needs 8 vCPU (2×D2 system + 1×D4 app) and would fail at
apply with a quota error.

---

## The shape that fits

```
2 × Standard_B2s   =   4 vCPU   =   the entire quota
```

Burstable is the cheapest family that still meets the AKS system-pool minimum
of 2 vCPU / 4 GiB. There is no room for a second pool, so the cluster runs a
single **untainted** pool — the `aks` module drops
`only_critical_addons_enabled` automatically when `enable_app_pool = false`,
because a tainted single pool would leave nothing able to schedule.

Two consequences of the B-series choice, both handled in the module:

- **Managed OS disks, not ephemeral.** Ephemeral needs a VM cache at least as
  large as the disk, which burstable sizes do not have.
- **No availability zones.** B-series has no zone support here.

---

## What is switched off, and what it saves

| Disabled | What it buys in production | ~Monthly cost avoided |
|---|---|---|
| NAT gateway | Static, allowlistable egress IP ([ADR-003](DECISIONS.md#adr-003)) | ~€32 + data |
| Private endpoints | SQL/Key Vault/ACR off the public internet | ~€7 each |
| Private DNS zones | Resolution for those endpoints | ~€0.45 each |
| Azure SQL | The reference app runs without it | ~€5–15 |
| Managed Grafana | Dashboards | ~€45 |
| Defender for Containers | Runtime threat detection | ~€5/vCPU |
| AKS Standard tier | Uptime SLA | ~€65 |

## What is **not** switched off

Cost was cut; controls were not. Verified against the plan output:

```
PASS  AKS local accounts disabled        PASS  ACR admin user disabled
PASS  AKS workload identity enabled      PASS  Key Vault uses RBAC not policies
PASS  AKS OIDC issuer enabled            PASS  Key Vault ACL default-deny
PASS  AKS Azure RBAC enabled             PASS  Key Vault ACL allows only my IP
PASS  AKS API server IP-restricted       PASS  Storage no shared account keys
PASS  AKS network policy = cilium        PASS  Storage ACL default-deny
PASS  AKS image cleaner on               PASS  Storage TLS 1.2 minimum
PASS  AKS KV secrets provider rotation   PASS  Storage HTTPS only
PASS  Workload identity federated        PASS  Storage no public blobs
PASS  Budget guard rail present
```

The API server, Key Vault and storage are all default-deny and allow exactly
one address: the operator's public IP, written into `terraform.tfvars` by
`make sandbox-tfvars`. If your IP changes, re-run it and re-apply.

---

## Running it

```bash
az login

cd lab
make sandbox-quota                 # confirm the quota before spending time
make sandbox-tfvars                # writes tfvars from the current login + your IP
make init  ENV=sandbox             # local state, by design
make plan  ENV=sandbox
make apply ENV=sandbox             # prompts for confirmation

make kubeconfig ENV=sandbox
kubectl get nodes

make sandbox-cost                  # month-to-date spend (billing lags ~24h)
make destroy ENV=sandbox           # tear down — this bills by the hour
```

State is **local on purpose**. The sandbox is created and destroyed on a
subscription with no shared team backend, and bootstrapping remote state would
cost more than the environment it tracks. Every other environment uses the
`azurerm` backend from `lab/terraform/bootstrap`.

---

## Costs

58 resources are created. Only a few of them bill meaningfully:

| Resource | Rate | ~Monthly if left running |
|---|---|---|
| 2 × Standard_B2s nodes | ~€0.038/hr each | **~€55** |
| Managed disks (2 × 32 GB) | — | ~€4 |
| Load balancer + public IP | ~€0.023/hr | ~€17 |
| ACR Basic | ~€0.15/day | ~€5 |
| Log Analytics | 5 GB/month free, capped at 0.5 GB/day | ~€0 |
| Key Vault standard | per-operation | <€1 |
| Storage LRS | per-GB | <€1 |
| AKS control plane (Free tier) | — | €0 |
| **Total** | | **~€80/month, or ~€2.70/day** |

A budget alert at €50 with notifications at 50%, 80% and forecast 100% is
created as part of the environment. It does not stop spending — Azure budgets
alert, they do not enforce — so **destroy the environment when you are done**.

Scaling the node pool to its minimum of 1 node roughly halves the compute cost
if you want it up but idle:

```bash
az aks nodepool scale -g rg-rebtel-lab-sandbox-aks -n system \
  --cluster-name aks-rebtel-lab-sandbox --node-count 1
```

---

## What this exercise found

Running a real plan against a real subscription caught a defect that no amount
of `terraform validate` would have:

**`count` gated on a value computed by another resource.** Eleven resources
across four modules used `count = var.some_id == "" ? 0 : 1`, where `some_id`
comes from a resource created in the same apply. Terraform cannot evaluate that
at plan time and fails with *"Invalid count argument"*. It affected dev,
staging and prod too — the modules validated cleanly and would have failed on
first use.

All of them now gate on plain booleans (`enable_diagnostics`,
`enable_csi_driver_access`, `enable_acr_pull_assignment`, …) that are known
before the graph is walked.

This is the argument for having a sandbox at all: `validate` checks syntax and
types, `plan` checks the graph, and only the second one finds this class of
bug.
