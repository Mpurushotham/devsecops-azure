# Azure DevSecOps — End-to-End Solution

A production-grade DevSecOps implementation for Azure Kubernetes Service (AKS) covering
shift-left security, supply-chain integrity, runtime protection, and full-stack observability.

---

## Architecture Overview

### 1 · Secure CI/CD Pipeline

```
Dev           Git commit ──► Pull Request ──────────────► Branch merge
                             (peer + security review)      (protected, signed)
                                    │
CI            CI trigger ──► Build  └──────────────────► Unit/int tests
              (GH Actions)   (reproducible, pinned)        (SonarQube coverage)
                                    │
Security      SAST ──► SCA/Deps ──► Image scan ──────► DAST
              (Semgrep)  (Trivy,     (Trivy, Grype)     (OWASP ZAP,
               Bandit)    Snyk)                           Nuclei)
                                    │
Artifacts     Sign artifact ────────────────────────► Artifact store
              (cosign + SLSA)                          (ACR)
                                    │
Deploy        Staging ──► Approval gate ────────────► Production
              (smoke test)  (manual in sec-critical)   (blue/green, ArgoCD)
```

### 2 · DevSecOps Security Gates

| Stage | Tool | Action |
|-------|------|--------|
| **Code** | detect-secrets, gitleaks | Pre-commit hooks block secrets |
| **PR / Review** | Semgrep, Bandit | SAST on changed files |
| **Build** | Trivy (filesystem) | SCA — dependency vulnerability scan |
| **Test** | OWASP ZAP, Nuclei | DAST against ephemeral environment |
| **Release** | cosign + SLSA | Sign image + generate SBOM |
| **Runtime** | Falco, Defender for Containers | Anomaly detection → SIEM |

**CVSS Threshold Policy:**
- `CVSS ≥ 9.0` → **Block build** (Critical)
- `CVSS 7.0–8.9` → **Warn + create ticket** (High)
- `CVSS < 7.0` → **Log only** (Medium/Low)

### 3 · Kubernetes Platform (AKS Multi-Zone)

```
Azure Subscription
└── AKS Cluster (multi-zone)
    ├── Control Plane — managed by Azure (etcd encrypted with CMK)
    ├── Node Pool Zone A — System pods
    ├── Node Pool Zone B — App pods
    ├── Node Pool Zone C — App pods
    ├── Ingress — AGIC / NGINX + TLS (cert-manager → Let's Encrypt)
    ├── Service Mesh — Istio (STRICT mTLS, AuthorizationPolicies)
    ├── Network — Deny-all NetworkPolicies, Azure CNI
    ├── Admission — Kyverno policies (image digest, no-root, resource limits)
    ├── Runtime — Falco (eBPF rules → Falcosidekick → Loki/Alertmanager)
    └── Threat Detection — Microsoft Defender for Containers
```

### 4 · Observability Stack

```
Applications (/metrics · logs · traces)
K8s infra (kube-state-metrics, node-exporter)
     │
     ├─► Prometheus ──► VictoriaMetrics (long-term storage)
     │   (AlertManager, Thanos HA)
     │
     ├─► Fluent Bit (DaemonSet) ──► Loki (log aggregation)
     │
     └─► OTel Collector ──► Tempo / Jaeger (trace store)
                │
                └──────────────────► Grafana (dashboards, SLO, alerts)
                                          │
                                    PagerDuty / OpsGenie (on-call)
```

---

## Repository Structure

```
devsecops/
├── .github/workflows/
│   ├── ci-pipeline.yml        # End-to-end CI/CD with all security gates
│   ├── security-gates.yml     # PR-triggered security checks
│   ├── release.yml            # Release: SBOM + cosign + SLSA
│   └── dast.yml               # Scheduled DAST (OWASP ZAP + Nuclei)
│
├── infrastructure/terraform/
│   ├── aks/                   # AKS cluster (multi-zone, etcd CMK, OIDC)
│   ├── security/              # Defender for Cloud, Sentinel, Key Vault
│   └── monitoring/            # Log Analytics, Managed Grafana, DCR
│
├── kubernetes/
│   ├── base/                  # Namespaces, RBAC
│   ├── security/
│   │   ├── kyverno/policies/  # Admission policies (5 policies)
│   │   ├── falco/             # Runtime detection rules (7 rules)
│   │   └── network-policies/  # Default deny-all + allow rules
│   ├── service-mesh/istio/    # mTLS PeerAuthentication + AuthorizationPolicies
│   ├── cert-manager/          # ClusterIssuers (LE prod/staging, self-signed)
│   ├── ingress/               # NGINX ingress with security headers + WAF
│   └── argocd/                # ArgoCD Application + AppProject
│
├── observability/
│   ├── prometheus/            # Prometheus config + alert rules (3 groups)
│   ├── alertmanager/          # PagerDuty / OpsGenie / Slack routing
│   ├── fluent-bit/            # DaemonSet: log ship → Loki + Azure Log Analytics
│   ├── loki/                  # Log aggregation (Azure Blob backend, 30d retention)
│   ├── tempo/                 # Trace store (OTLP/Jaeger/Zipkin, 7d retention)
│   ├── otel-collector/        # Unified telemetry pipeline
│   └── grafana/dashboards/    # Security Overview + SLO dashboard
│
├── security/
│   ├── .pre-commit-config.yaml  # 10 hook categories (secrets, SAST, IaC, Dockerfile)
│   ├── .gitleaks.toml           # Azure-specific secret patterns
│   ├── semgrep/.semgrep.yml     # 16 custom SAST rules (CWE-mapped)
│   ├── trivy/                   # Trivy config + ignore list
│   └── zap-rules.tsv            # ZAP scan policy
│
├── app/
│   ├── Dockerfile               # Multi-stage, non-root, hardened
│   ├── requirements.txt         # Pinned dependencies
│   ├── src/main.py              # Flask app with OTel, Prometheus, security headers
│   └── tests/test_main.py       # Unit tests including security header checks
│
└── scripts/
    ├── setup-aks.sh             # Bootstrap AKS + all components
    ├── install-security-tools.sh # Install Trivy, cosign, Syft, Semgrep, etc.
    └── generate-sbom.sh         # Generate + sign CycloneDX/SPDX SBOM
```

---

## Quick Start

### Prerequisites

```bash
# Install all security tools
./scripts/install-security-tools.sh

# Verify tools
trivy --version && cosign version && syft --version && semgrep --version
```

### 1 · Bootstrap Infrastructure

```bash
# Set Azure credentials
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Provision AKS + security resources + monitoring
cd infrastructure/terraform/aks
terraform init && terraform apply -var="environment=staging"

# Bootstrap cluster
./scripts/setup-aks.sh staging
```

### 2 · Configure GitHub Secrets and Variables

The workflows read credentials from **secrets** (`secrets.*`) and non-sensitive
configuration from **repository variables** (`vars.*`). Setting a variable as a
secret — or the reverse — silently yields an empty value at runtime.

**Secrets** (`Settings → Secrets and variables → Actions → Secrets`):

| Secret | Description |
|--------|-------------|
| `AZURE_CREDENTIALS` | Azure service principal JSON (used by `azure/login`) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `ACR_USERNAME` | ACR username |
| `ACR_PASSWORD` | ACR password |
| `SONAR_TOKEN` | SonarQube/SonarCloud token — scan is skipped when unset |
| `SNYK_TOKEN` | Snyk API token — scan is skipped when unset |
| `SEMGREP_APP_TOKEN` | Semgrep App token (optional; OSS rules run without it) |
| `FOSSA_API_KEY` | FOSSA token — falls back to `pip-licenses` when unset |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token (staging) |
| `ARGOCD_PROD_AUTH_TOKEN` | ArgoCD API token (production) |
| `AZURE_MONITOR_WEBHOOK_URL` | Deploy notification webhook |
| `SLACK_WEBHOOK_URL` | Slack webhook for notifications |

**Variables** (`Settings → Secrets and variables → Actions → Variables`):

| Variable | Description |
|----------|-------------|
| `ACR_REGISTRY` | ACR login server (e.g. `myacr.azurecr.io`) |
| `ACR_PROD_REGISTRY` | Production ACR login server |
| `ACR_REPOSITORY` | Image repository name (e.g. `devsecops-app`) |
| `SONAR_HOST_URL` | SonarQube server URL |
| `ARGOCD_SERVER` / `ARGOCD_PROD_SERVER` | ArgoCD server hostnames |
| `AKS_RESOURCE_GROUP` / `AKS_CLUSTER_NAME` | Staging AKS target |
| `AKS_PROD_RESOURCE_GROUP` / `AKS_PROD_CLUSTER_NAME` | Production AKS target |
| `STAGING_URL` / `PRODUCTION_URL` / `PRODUCTION_GREEN_URL` | Smoke-test endpoints |
| `DAST_RESOURCE_GROUP` | Resource group for the ephemeral DAST environment |

Scanners that depend on a third-party service (SonarQube, Snyk, FOSSA) and the
nightly DAST environment **skip with a notice** when their credentials are
absent, so a fork without those accounts still gets a green, meaningful gate.

### 3 · Run Security Scans Locally

```bash
# SAST scan
semgrep --config=security/semgrep/.semgrep.yml .

# Secret detection
gitleaks detect --config=security/.gitleaks.toml

# Container image scan
trivy image --config=security/trivy/trivy-config.yaml myacr.azurecr.io/devsecops-app:latest

# SBOM generation + signing
./scripts/generate-sbom.sh myacr.azurecr.io/devsecops-app:latest

# Verify image signature
cosign verify \
  --certificate-identity-regexp="https://github.com/org/repo/*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  myacr.azurecr.io/devsecops-app:latest
```

### 4 · Deploy Application

```bash
# Push a commit to trigger the pipeline
git push origin main

# Or manually trigger DAST
gh workflow run dast.yml

# Check ArgoCD sync status
argocd app get devsecops-app
```

---

## Compliance & Governance

| Control | Implementation |
|---------|---------------|
| **SBOM** | CycloneDX + SPDX generated by Syft, attached to every release image via cosign |
| **SLSA Level 3** | slsa-github-generator provenance attached to all release artifacts |
| **TLS everywhere** | cert-manager + Let's Encrypt, Istio STRICT mTLS inside the mesh |
| **Vulnerability SLA** | Critical: 24h, High: 7d, Medium: 30d — tracked via Trivy + GitHub Security tab |
| **Secrets management** | Azure Key Vault (etcd CMK, app secrets via CSI driver, no secrets in YAML) |
| **Audit logging** | AKS audit logs → Log Analytics → Sentinel (90-day retention) |
| **Policy-as-code** | Kyverno enforces image digest, non-root, registry allowlist, resource limits |
| **GitOps** | ArgoCD with SPIFFE-verified deployments, blue/green via Argo Rollouts |

---

## Falco Security Rules

Seven production-grade runtime detection rules covering:

| Rule | Severity | MITRE ATT&CK |
|------|----------|--------------|
| Shell spawned in container | CRITICAL | T1059 |
| Write to sensitive files (/etc/shadow, etc.) | CRITICAL | T1098 |
| Unexpected outbound network connection | WARNING | T1071 |
| Setuid binary execution | CRITICAL | T1548 |
| Container drift (new binary) | CRITICAL | T1611 |
| Crypto mining activity | CRITICAL | T1496 |
| kubectl/K8s API access from pod | CRITICAL | T1613 |

---

## Grafana Dashboards

| Dashboard | UID | Contents |
|-----------|-----|----------|
| Security Overview | `devsecops-security-overview` | Falco alerts, CVE counts, auth failures, cert expiry, recent events |
| SLO Dashboard | `devsecops-slo` | Availability (99.9% target), error rate, p50/90/99 latency, burn rate, error budget |

---

## Contributing

1. Fork and create a feature branch
2. Install pre-commit hooks: `pre-commit install`
3. All commits must pass secret detection, SAST, and Dockerfile linting
4. PRs require security review for changes to `security/`, `infrastructure/`, or `kubernetes/`

---

## References

- [Azure AKS Security Baseline](https://learn.microsoft.com/en-us/azure/aks/security-hardening)
- [Kyverno Policies](https://kyverno.io/policies/)
- [Falco Rules](https://falco.org/docs/rules/)
- [SLSA Framework](https://slsa.dev/)
- [OpenSSF Scorecard](https://securityscorecards.dev/)
- [MITRE ATT&CK for Containers](https://attack.mitre.org/matrices/enterprise/containers/)
