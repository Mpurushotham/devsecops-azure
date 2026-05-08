# Architecture Diagrams

All diagrams use [Mermaid](https://mermaid.js.org/) syntax and render natively in GitHub, GitLab, and most modern docs platforms.

| Diagram | Description | File |
|---------|-------------|------|
| **Secure CI/CD Pipeline** | End-to-end pipeline from commit to production with all security gates | [cicd-pipeline.md](./cicd-pipeline.md) |
| **DevSecOps Security Gates** | Shift-left security controls at every stage with CVSS threshold policy | [security-gates.md](./security-gates.md) |
| **AKS Kubernetes Platform** | Multi-zone AKS cluster with admission control, service mesh, and runtime security | [aks-platform.md](./aks-platform.md) |
| **Observability Stack** | Metrics (Prometheus/Thanos), logs (Fluent Bit/Loki), traces (OTel/Tempo), alerting (Grafana/PagerDuty) | [observability-stack.md](./observability-stack.md) |

## Quick Preview

### CI/CD Flow
```
Code → PR (security gates) → CI Build → SAST/SCA/DAST → Image Sign → Staging → ✅ Approval → Production
```

### Security Gate Summary
```
CVSS ≥ 9.0  →  ❌ Block build
CVSS 7-8.9  →  ⚠️ Warn + create ticket  
CVSS < 7.0  →  📝 Log only
```

### Observability Data Flow
```
App metrics/logs/traces
   ├── Prometheus → VictoriaMetrics → Grafana
   ├── Fluent Bit → Loki → Grafana
   └── OTel Collector → Tempo → Grafana
                              ↓
                         AlertManager → PagerDuty / OpsGenie / Slack
```
