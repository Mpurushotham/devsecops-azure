# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A reference DevSecOps platform for Azure/AKS. It is ~95% infrastructure-as-code, policy, and pipeline
definitions; the only application code is a small Flask service in `app/` that exists as a scan target
and a demonstration of the security/observability conventions the platform enforces.

Read `README.md` and `docs/ARCHITECTURE.md` for the four pillars (CI/CD, security gates, AKS platform,
observability) and the component inventory. This file covers what those documents don't.

## Commands

### Application (`app/`)

```bash
cd app
pip install -r requirements.txt && pip install pytest pytest-cov
python -m pytest tests/                      # all tests
python -m pytest tests/test_main.py::test_security_headers -v   # single test
python -m pytest tests/ --cov=src --cov-report=term-missing     # with coverage
black --check . && isort --check-only . && flake8 . --select=E9,F63,F7,F82
python -m src.main                           # run via gunicorn on $PORT (default 8080)
docker build -f Dockerfile -t devsecops-app:dev .   # build context MUST be app/
```

`setuptools` is a real runtime dependency in `requirements.txt`: `opentelemetry-instrumentation`
imports `pkg_resources` at module load and `python:3.12-slim` ships none, so removing it makes the
container crash on startup rather than fail a test.

Tests must run from `app/` — `tests/test_main.py` does `from src.main import app`, and `tests/__init__.py`
puts `app/` on `sys.path` only when pytest's rootdir resolution starts there.

### Pre-commit

```bash
pip install pre-commit && pre-commit install
pre-commit install --hook-type commit-msg    # enables commitizen (conventional commits)
pre-commit run --all-files
pre-commit run gitleaks --all-files          # single hook
detect-secrets scan --baseline .secrets.baseline   # refresh baseline after a legit new "secret"
```

`no-commit-to-branch` blocks commits to `main`/`master` — always work on a feature branch.

### Security scans (local)

```bash
semgrep --config=security/semgrep/.semgrep.yml .
gitleaks detect --config=security/.gitleaks.toml
trivy fs --config security/trivy/trivy-config.yaml .
trivy image --config security/trivy/trivy-config.yaml <registry>/<repo>:<tag>
bandit -ll --recursive app/src
./scripts/generate-sbom.sh <image:tag> [output-dir]   # syft CycloneDX+SPDX, grype scan, cosign attest
./scripts/install-security-tools.sh                   # trivy, cosign, syft, grype, semgrep, gitleaks, hadolint…
```

### Infrastructure

```bash
cd infrastructure/terraform/aks && terraform init && terraform validate
terraform plan -var="environment=staging"
./scripts/setup-aks.sh staging               # full cluster bootstrap; DRY_RUN=true to preview
```

`versions.tf` hardcodes an `azurerm` remote state backend (`tfstate-rg` / `tfstateaksstore`); `terraform init`
fails without access to it. The three Terraform directories (`aks/`, `security/`, `monitoring/`) are
independent root modules, not a composed workspace — apply each separately.

`setup-aks.sh` runs `terraform apply` then installs, in order: cert-manager, Istio, Kyverno, Falco,
kube-prometheus-stack/Loki/Tempo, ArgoCD, network policies. It is idempotent and re-runnable.

## Architecture conventions

### The CVSS threshold policy is the organizing rule

Every scanning stage — in workflows, in `generate-sbom.sh`, in the docs — implements the same policy:

- `CVSS ≥ 9.0` (SARIF `level: error`) → **fail the job**
- `CVSS 7.0–8.9` (SARIF `level: warning`) → emit `::warning::` and open a tracking GitHub issue
- `< 7.0` → log only

Enforcement is always an inline `python3 - <<'PYEOF'` heredoc that parses the tool's SARIF output and
counts `error`/`warning` results; the scanner action itself is run with `exit-code: "0"` so the heredoc
owns the pass/fail decision. Any new scanner must follow this shape: emit SARIF → upload it to the
Security tab with a distinct `category:` → gate on it in a heredoc.

### Workflows

| File | Trigger | Notes |
|---|---|---|
| `ci-pipeline.yml` | push/PR to `main`,`develop` | 12 jobs, lint → build → test → SAST → SCA → image → scan → DAST → sign → staging → prod |
| `security-gates.yml` | PR + dispatch | 7 jobs, changed-files-scoped: gitleaks, detect-secrets, Semgrep, Bandit, Trivy fs, TruffleHog3, FOSSA |
| `release.yml` | tag push `v*` | SBOM (CycloneDX+SPDX) → cosign keyless sign → attest → SLSA provenance → GitHub Release |
| `dast.yml` | daily cron + dispatch | ephemeral ACI deploy → ZAP full/baseline/API + Nuclei → tickets → teardown |

Deploy jobs verify the cosign signature (`cosign verify --certificate-identity-regexp …`) *before*
applying anything — keep that gate in front of any new deploy path.

`security-gates.yml` jobs scope themselves to changed files via a `Determine changed files` step and skip
cleanly when nothing relevant changed; preserve that pattern rather than scanning the whole tree on PRs.

### Kubernetes manifests must satisfy Kyverno

`kubernetes/security/kyverno/policies/` is admission control that will reject non-conforming manifests.
Four policies are `validationFailureAction: Enforce` — non-root, no privileged, resource limits present,
and approved-registry-only. `require-image-digest` is `Audit` outside production. Namespaces in
`kubernetes/base/namespaces.yaml` additionally set Pod Security Standards labels (`restricted` in
production, `baseline` in staging/monitoring, `privileged` in `security`/`istio-system`) and
`istio-injection: enabled`.

So: any new workload manifest needs `runAsNonRoot`, dropped capabilities, CPU/memory requests+limits, an
image from an approved registry, and — for production — a digest reference rather than a tag.

Istio `PeerAuthentication` is STRICT mTLS mesh-wide and `network-policies/default-deny-all.yaml` denies
all traffic; new services need an explicit `AuthorizationPolicy` and NetworkPolicy allow rule.

### Application conventions (`app/src/main.py`)

The `after_request` hook is load-bearing: it sets the six security headers, strips `Server`, and records
the `http_requests_total` / `http_request_duration_seconds` Prometheus metrics. `tests/test_main.py`
asserts on those headers — changes there must keep the tests passing. Handlers wrap work in
`tracer.start_as_current_span(...)`, log through `structlog` (JSON), and the service exposes
`/healthz`, `/readyz`, `/metrics`, `/api/v1/*`.

## Optional third-party scanners degrade, they don't fail

SonarQube, Snyk, FOSSA and the nightly DAST environment all check for their credentials first and skip
with a `::notice::` when unset, so a fork without those accounts still gets a green, meaningful gate.
Keep that pattern when adding a scanner that needs an account — a missing optional credential must never
be indistinguishable from a real finding.

`upload-sarif` steps are guarded with `hashFiles('x.sarif') != ''` because `if: always()` alone will fail
the job when the scanner errored before writing a report.

## Structural notes

- **No deployment manifests for the app itself** — deployment is delegated to ArgoCD
  (`kubernetes/argocd/application.yaml`) pointing at a Helm chart outside this repo. The `lab/` tree
  does ship its own charts.
- **`lab/` is a self-contained second solution** (see `lab/README.md`) targeting a multi-cloud
  Azure+GCP platform with GitOps and a containerized .NET workload. It reuses this repo's security
  gates but has its own Terraform, Helm charts and pipelines. Don't cross-wire the two.

## Secrets and variables

Pipelines read Azure/ACR/ArgoCD/scanner credentials from GitHub **secrets** and non-sensitive config
(`ACR_REGISTRY`, `ACR_REPOSITORY`, `SONAR_HOST_URL`, `STAGING_URL`, cluster names) from GitHub
**variables**. The README lists both tables. Cluster-side secrets come from Azure Key Vault via the CSI
driver; nothing is committed in YAML, and `security/.gitleaks.toml` carries Azure-specific patterns to
keep it that way — always pass `--config security/.gitleaks.toml`, since the default ruleset flags the
`.secrets.baseline` file itself.
