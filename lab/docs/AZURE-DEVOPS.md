# Azure DevOps — what is wired, and the one thing that is not

The organisation runs both GitHub Actions and Azure DevOps, so the ADO pipeline
mirrors `.github/workflows/lab-terraform.yml` step for step and calls the *same*
CVSS gate script rather than carrying a second copy of the policy
([ADR-016](DECISIONS.md#adr-016)).

**Org:** `https://dev.azure.com/ADODemotests` · **Project:** `DevOps-Demo`

---

## Built and verified

| Component | State | Detail |
|---|---|---|
| Pipeline | **Created** | `lab-terraform`, id 3, from the GitHub repo via the existing GitHub App connection |
| YAML compilation | **Passing** | Compiles cleanly; stages and jobs are scheduled |
| Service connection | **Created and resolving** | `sc-platform-sandbox`, **workload identity federation** — no client secret |
| Azure-side trust | **Created** | `id-ado-terraform` managed identity, federated credential bound to the connection's issuer and subject |
| Authorisation | **Granted** | Owner on the subscription (Terraform creates role assignments; Contributor cannot) |
| Remote state | **Migrated** | Sandbox state moved from local to Azure Blob so a pipeline can operate it |
| Pipeline variables | **Set** | `azureServiceConnection`, `TF_STATE_RG`, `TF_STATE_SA` |

The service connection uses the same no-stored-credential model as the GitHub
path: ADO issues a token, Entra exchanges it for an access token, and the
federated credential pins that exchange to one specific service connection.
There is no secret in a variable group.

```
issuer  : https://login.microsoftonline.com/<tenant>/v2.0
subject : /eid1/c/pub/t/.../sc/<project>/<service-connection-id>
```

---

## The blocker

```
No hosted parallelism has been purchased or granted.
```

Microsoft stopped auto-granting the free hosted-agent tier to new Azure DevOps
organisations. It is an **account-level grant, not a defect in the pipeline** —
and the distinction is visible in the run history:

| Run | Failure | Meaning |
|---|---|---|
| 3 | `service connection could not be found` | A real YAML defect — a runtime `condition` cannot hide an unresolvable service connection, because ADO validates the whole file at compile time |
| 5 | `No hosted parallelism…` | The YAML compiled, the service connection resolved, jobs were scheduled — and then there was no agent to run them on |

Run 5 failing *later in the lifecycle* than run 3 is the evidence that the
pipeline itself is correct.

### Three ways to unblock it

**1. Request the free grant** (recommended, free, 2–3 business days)

<https://aka.ms/azpipelines-parallelism-request> — one form, asking for the free
Microsoft-hosted tier for a private project. Grants 1 parallel job and
1,800 minutes/month.

**2. Register a self-hosted agent** (immediate, needs a PAT)

Agent registration requires a Personal Access Token, and minting one
programmatically requires an interactive browser sign-in that CI cannot perform.
Create it in the ADO UI — *User settings → Personal access tokens → New*, scope
**Agent Pools (read, manage)** — then:

```bash
# On any Linux/macOS machine, or as a pod in the cluster
mkdir -p ~/ado-agent && cd ~/ado-agent
curl -sSfLO https://vstsagentpackage.azureedge.net/agent/4.248.0/vsts-agent-osx-arm64-4.248.0.tar.gz
tar zxf vsts-agent-*.tar.gz
./config.sh --unattended \
  --url https://dev.azure.com/ADODemotests \
  --auth pat --token "<PAT>" \
  --pool Default --agent "$(hostname)" --acceptTeeEula
./run.sh
```

Then set `pool: { name: Default }` in the pipeline instead of `vmImage`.

**3. Buy a parallel job** — about €35/month. Hard to justify for a lab.

---

## Why the pipeline avoids marketplace tasks

The obvious way to install Terraform in ADO is `TerraformInstaller@1` from the
Terraform marketplace extension. This pipeline does not use it.

An extension has to be installed at the *organisation* level by an admin. A
pipeline that cannot run until someone with elevated rights installs something
is a pipeline that will not run in a fresh org, a fork, or a disaster-recovery
rebuild. Terraform, tflint and Trivy are installed instead from
checksum-verified release assets — the same approach the GitHub workflows take,
for the same reason: these binaries build and audit the infrastructure, so a
compromised installer compromises the evidence.

---

## What running it will exercise

Once an agent is available, the Validate stage runs with no cloud credentials at
all:

- `terraform fmt -check -recursive`
- `tflint` across all modules, environments and bootstrap
- `terraform validate` across the same
- Trivy IaC scan, gated by `.github/scripts/cvss_gate.py` — the identical
  implementation the GitHub workflow calls
- `helm lint`, chart render, and the 17-check platform security contract

Plan and Apply then use the federated service connection against the sandbox's
remote state. Apply is bound to an ADO **Environment** (`platform-sandbox`), so
the approval check lives there rather than in this file — a pipeline edit cannot
remove the gate.

---

## Reproducing the setup

Everything above was created from the CLI and can be re-created:

```bash
az extension add --name azure-devops
az devops configure --defaults \
  organization=https://dev.azure.com/ADODemotests project=DevOps-Demo

# Identity for ADO to federate into
az group create -n rg-rebtel-lab-cicd -l swedencentral
az identity create -n id-ado-terraform -g rg-rebtel-lab-cicd

# Service connection (workload identity federation), then read back the
# issuer/subject it generates and bind a federated credential to them
az devops service-endpoint create --service-endpoint-configuration sc.json
az identity federated-credential create \
  --name fic-ado-sandbox --identity-name id-ado-terraform \
  --resource-group rg-rebtel-lab-cicd \
  --issuer "<issuer from the connection>" \
  --subject "<subject from the connection>" \
  --audiences api://AzureADTokenExchange

# Pipeline
az pipelines create --name lab-terraform \
  --repository https://github.com/Mpurushotham/devsecops-azure \
  --repository-type github --branch chore/pre-commit-setup \
  --yml-path lab/azure-pipelines/terraform-pipeline.yml \
  --service-connection <github-service-connection-id> --skip-first-run true
```

One caveat worth recording: `az rest` cannot authenticate to `dev.azure.com`
with an ordinary `az login` session — it redirects to interactive sign-in with
*"Identity has not been materialized"*. The `az devops` extension uses a
different auth path and works. Use `az devops invoke` for raw API calls rather
than `az rest`.
