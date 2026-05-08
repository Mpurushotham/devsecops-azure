# DevSecOps Solution — Architecture Reference

This document provides a high-level overview of the four architectural pillars
of the Azure DevSecOps solution.

---

## Pillars

| Pillar | Description | Key Files |
|--------|-------------|-----------|
| [Secure CI/CD Pipeline](./diagrams/cicd-pipeline.md) | GitHub Actions with 12-stage secure pipeline | `.github/workflows/` |
| [DevSecOps Security Gates](./diagrams/security-gates.md) | Shift-left security at every SDLC stage | `security/`, `.github/workflows/security-gates.yml` |
| [AKS Kubernetes Platform](./diagrams/aks-platform.md) | Multi-zone AKS with admission control + runtime security | `kubernetes/`, `infrastructure/terraform/aks/` |
| [Observability Stack](./diagrams/observability-stack.md) | Full-stack telemetry: metrics, logs, traces, alerts | `observability/` |

---

## Component Inventory

### CI/CD Workflows
| File | Trigger | Purpose |
|------|---------|---------|
| `ci-pipeline.yml` | push/PR | Full 12-job pipeline |
| `security-gates.yml` | PR | 7-job security gate check |
| `release.yml` | tag push | SBOM + sign + SLSA + GitHub Release |
| `dast.yml` | daily + on-demand | OWASP ZAP + Nuclei DAST |

### Infrastructure (Terraform)
| Module | Resources |
|--------|-----------|
| `aks/` | Cluster, node pools (3-zone), ACR, Key Vault (CMK), managed identity, Log Analytics |
| `security/` | Defender for Cloud, Sentinel, Azure Policy (CIS), diagnostic settings |
| `monitoring/` | Azure Monitor workspace, Managed Grafana, DCR, alert rules |

### Kubernetes Security
| Component | Files | Purpose |
|-----------|-------|---------|
| Kyverno | `security/kyverno/policies/` (5 policies) | Admission control |
| Falco | `security/falco/` (config + 7 rules) | Runtime detection |
| Network Policies | `security/network-policies/` | Default deny-all + allow rules |
| Istio | `service-mesh/istio/` | STRICT mTLS + AuthorizationPolicies |
| cert-manager | `cert-manager/` | Let's Encrypt + internal CA |
| NGINX Ingress | `ingress/` | TLS + security headers + WAF |
| ArgoCD | `argocd/` | GitOps deploy + AppProject RBAC |

### Observability
| Component | Config File | Backend |
|-----------|------------|---------|
| Prometheus | `prometheus/prometheus-config.yaml` | Local + Thanos remote |
| Alert Rules | `prometheus/alert-rules.yaml` | 3 groups: security, SLO, infra |
| AlertManager | `alertmanager/alertmanager-config.yaml` | PagerDuty / OpsGenie / Slack |
| Fluent Bit | `fluent-bit/fluent-bit-config.yaml` | Loki + Azure Log Analytics |
| Loki | `loki/loki-config.yaml` | Azure Blob Storage |
| Tempo | `tempo/tempo-config.yaml` | Azure Blob Storage |
| OTel Collector | `otel-collector/otel-config.yaml` | Tempo + Prometheus + Loki |
| Grafana | `grafana/dashboards/` | 2 dashboards |

---

## Security Tool Matrix

| Tool | Stage | What it checks | Block threshold |
|------|-------|----------------|----------------|
| detect-secrets | Pre-commit | Hardcoded secrets | Any detection |
| gitleaks | Pre-commit + PR | Git history secrets | Any detection |
| Semgrep | PR | SAST (OWASP, CWE-25) | ERROR level |
| Bandit | PR | Python SAST | HIGH/HIGH |
| Trivy (fs) | PR + Build | Dependency CVEs | CRITICAL |
| Snyk | Build | Dependency CVEs + license | HIGH |
| TruffleHog3 | PR | Verified secrets | Any verified |
| FOSSA | PR | License compliance | Policy violation |
| Trivy (image) | Post-build | Container CVEs | CRITICAL |
| Grype | Post-build | Container CVEs | CRITICAL |
| OWASP ZAP | Test | DAST web scan | High alert |
| Nuclei | Test | CVE exploitation | CRITICAL |
| cosign | Release | Image signing | Verification failure |
| Falco | Runtime | Container behavior | CRITICAL rule |
| Kyverno | Deploy | K8s admission | Policy violation |

---

## Quick Start Checklist

- [ ] Install security tools: `./scripts/install-security-tools.sh`
- [ ] Configure GitHub Secrets (see README.md)
- [ ] Provision infrastructure: `cd infrastructure/terraform/aks && terraform apply`
- [ ] Bootstrap cluster: `./scripts/setup-aks.sh production`
- [ ] Verify Kyverno policies: `kubectl get clusterpolicy`
- [ ] Verify Falco running: `kubectl get pods -n security -l app=falco`
- [ ] Access Grafana: `kubectl get svc -n monitoring kube-prometheus-stack-grafana`
- [ ] Trigger first pipeline: `git push origin main`
