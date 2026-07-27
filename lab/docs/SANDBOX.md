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
| AKS versions available | 1.34/1.35/1.36 mainstream; 1.31–1.33 LTS-only |
| Role | Owner on the subscription — required, since the modules create role assignments |

**The 4 vCPU quota is the binding constraint** and it dictates the topology.
For comparison, `dev` needs 8 vCPU (2×D2 system + 1×D4 app) and would fail at
apply with a quota error.

---

## The shape that fits

```
2 × Standard_B2s_v2   =   4 vCPU   =   the entire quota
```

Burstable is the cheapest family that still meets the AKS system-pool minimum.
Note `Standard_B2s` (v1) is **not offered on this subscription** — the apply
fails with *"The VM size ... is not allowed in your subscription"*. Check before
choosing:

```bash
az vm list-skus -l swedencentral --size Standard_B --query "[].name" -o tsv
```

There is no room for a second pool, so the cluster runs a single **untainted**
pool — the `aks` module drops
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

61 resources are created. Only a few of them bill meaningfully:

| Resource | Rate | ~Monthly if left running |
|---|---|---|
| 2 × Standard_B2s_v2 nodes | ~€0.042/hr each | **~€61** |
| Managed disks (2 × 32 GB) | — | ~€4 |
| Load balancer + public IP | ~€0.023/hr | ~€17 |
| ACR Basic | ~€0.15/day | ~€5 |
| Log Analytics | 5 GB/month free, capped at 0.5 GB/day | ~€0 |
| Key Vault standard | per-operation | <€1 |
| Storage LRS | per-GB | <€1 |
| AKS control plane (Free tier) | — | €0 |
| **Total** | | **~€86/month, or ~€2.90/day** |

A budget alert at €50 with notifications at 50%, 80% and forecast 100% is
created as part of the environment. It does not stop spending — Azure budgets
alert, they do not enforce — so **destroy the environment when you are done**.

Scaling to the pool minimum of 1 node halves the compute cost if you want the
cluster up but idle — though note that the AKS addons then do not all fit, so
some system pods stay `Pending`:

```bash
az aks nodepool scale -g rg-rebtel-lab-sandbox-aks -n system \
  --cluster-name aks-rebtel-lab-sandbox --node-count 1
```

---

## Deployment result

Applied successfully. **61 resources across 6 resource groups**, AKS 1.34.9,
both nodes `Ready`, and the reference application serving traffic.

```
$ kubectl get nodes -L workload-type
NAME                             STATUS   VERSION   WORKLOAD-TYPE
aks-system-23492049-vmss000000   Ready    v1.34.9   application
aks-system-23492049-vmss000001   Ready    v1.34.9   application

$ curl http://payments-api.../healthz
{"status":"ok"}
```

Security posture verified on the **running** pod, not just in the plan:

```
image digest-pinned          True                    seccompProfile       RuntimeDefault
runAsNonRoot                 True                    SA token automounted False
runAsUser                    64198                   workload identity    true
readOnlyRootFilesystem       True                    NetworkPolicy        default-deny + explicit allow
allowPrivilegeEscalation     False                   Pod Security         restricted (enforcing)
capabilities dropped         ['ALL']
```

Workload identity is genuinely wired: the webhook injected `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID` and a projected token at
`/var/run/secrets/azure/tokens/azure-identity-token`. No secret was created.

Two controls proved themselves by **rejecting** legitimate-looking work during
verification, which is the only way to know they are live:

- Pod Security `restricted` refused a debug pod that omitted
  `allowPrivilegeEscalation: false` and capability drops.
- The default-deny NetworkPolicy blocked an in-cluster probe from another pod;
  the app was only reachable via `kubectl port-forward`, because the chart's
  policy allows ingress from `ingress-nginx` and nothing else.

---

## What this exercise found

Nine defects, in three waves. **`terraform validate` found none of them** — it
had been passing cleanly for every one.

### Wave 1 — found by `plan` (the graph)

**`count` gated on a value computed by another resource.** Eleven resources
across four modules used `count = var.some_id == "" ? 0 : 1`, where `some_id`
comes from a resource created in the same apply. Terraform cannot evaluate that
at plan time and fails with *"Invalid count argument"*. It affected dev, staging
and prod equally. All now gate on plain booleans known before the graph is
walked.

### Wave 2 — found by `apply` (the Azure API)

| Failure | Cause | Fix |
|---|---|---|
| `K8sVersionNotSupported` | 1.31 has left mainstream support and is LTS-only | Default moved to 1.34 |
| `SubnetsHaveNoServiceEndpointsConfigured` | A subnet must carry a service endpoint before it can appear in a PaaS network ACL | `service_endpoints` on the cluster subnets |
| `ip_rules must start with IPV4 address` | Azure storage ACLs reject a `/32` suffix | Normalised at the module boundary |
| `VM size not allowed in your subscription` | `Standard_B2s` (v1) is not offered here | `Standard_B2s_v2`, verified against the SKU list |
| `KeyBasedAuthenticationNotPermitted` | `shared_access_key_enabled = false`, but the provider's own data-plane polling used a key | `storage_use_azuread = true` |
| `403 ForbiddenByRbac` on a secret write | Entra RBAC is eventually consistent; the assignment had not converged | `time_sleep` gating the vault id output |

### Wave 3 — found by running a workload on it

| Failure | Cause | Fix |
|---|---|---|
| `FailedScheduling: didn't match node affinity` | The chart selects `workload-type: application`; a single-pool cluster had no such node | The AKS module labels the system pool when there is no app pool, so one chart works in every topology |
| `401 Unauthorized` from the registry | The kubelet identity had no AcrPull. The AKS module cannot grant it — ACR is created *after* AKS, so referencing it there is a cycle | The assignment moved to the module that owns the registry |
| 2 pods `Pending`, `Insufficient cpu` | AKS system addons request ~1.8 of 2 vCPU on one B2s_v2 | Autoscaler scaled 1→2 nodes and resolved it |

That last one is worth stating plainly: **on a 4 vCPU quota, the AKS platform
components consume most of one node.** Two nodes are needed before any workload
fits, which is why `system_pool_max_count` is 2 and why both nodes are running.

The pattern across all three waves is the same: each layer catches a class of
defect the previous one structurally cannot. `validate` checks syntax and types,
`plan` checks the dependency graph, `apply` checks what Azure will actually
accept, and only running a workload checks that the platform is usable.
