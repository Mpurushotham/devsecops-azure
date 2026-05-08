# Observability Stack — Architecture

```mermaid
flowchart LR
    subgraph SOURCES["Data Sources"]
        direction TB
        APP["Applications\n/metrics · logs · traces"]
        K8S["K8s Infra\nkube-state · node-exporter"]
    end

    subgraph METRICS["Metrics Pipeline"]
        direction TB
        PROM["Prometheus\nScrape + recording rules\nAlertManager\nThanos (HA)"]
        VM["VictoriaMetrics\nLong-term storage\n(1 year retention)"]
        PROM -->|remote write| VM
    end

    subgraph LOGS["Logs Pipeline"]
        direction TB
        FB["Fluent Bit\nDaemonSet log shipper\nKubernetes metadata"]
        LOKI["Loki\nLog aggregation\nAzure Blob backend\n30-day retention"]
        ALA["Azure Log Analytics\n(SIEM integration)\n90-day retention"]
        FB -->|labels| LOKI
        FB -->|audit logs| ALA
    end

    subgraph TRACES["Traces Pipeline"]
        direction TB
        OTEL["OTel Collector\nOTLP receiver\nk8s attribute enrichment"]
        TEMPO["Tempo / Jaeger\nTrace store\nAzure Blob backend\n7-day retention"]
        OTEL -->|OTLP| TEMPO
    end

    subgraph VIZ["Visualization & Alerting"]
        direction TB
        GRAFANA["Grafana\nDashboards\nAlert rules\nSLO tracking"]
        AM["AlertManager\nRoute: critical→PD, high→OG, info→Slack"]
    end

    subgraph ONCALL["On-call Routing"]
        PD["PagerDuty\nImmediate (P1/P2)"]
        OG["OpsGenie\n15min delay (P3)"]
        SLACK["Slack\nInformational"]
    end

    SOURCES -->|scrape| METRICS
    SOURCES -->|ship| LOGS
    SOURCES -->|export| TRACES

    VM -->|query| GRAFANA
    LOKI -->|query| GRAFANA
    TEMPO -->|query| GRAFANA

    GRAFANA -->|fire alert| AM
    AM --> PD & OG & SLACK

    classDef blue fill:#1a5276,color:#fff,stroke:#154360
    classDef green fill:#117a65,color:#fff,stroke:#0e6655
    classDef orange fill:#d35400,color:#fff,stroke:#ba4a00
    classDef gray fill:#566573,color:#fff,stroke:#424949
    classDef red fill:#c0392b,color:#fff,stroke:#922b21

    class APP,K8S gray
    class PROM,VM blue
    class FB,LOKI,ALA green
    class OTEL,TEMPO orange
    class GRAFANA,AM blue
    class PD red
    class OG,SLACK gray
```

## Component Reference

### Metrics — Prometheus Stack
| Component | Role | Config |
|-----------|------|--------|
| Prometheus | Scrape + rules + alerts | `prometheus-config.yaml` |
| Thanos Sidecar | Block upload + HA | Sidecar per Prometheus replica |
| VictoriaMetrics | Long-term storage (1yr) | Remote write target |
| AlertManager | Alert routing | `alertmanager-config.yaml` |
| kube-state-metrics | K8s object metrics | Deployment, pods, PVC |
| node-exporter | Node-level metrics | CPU, RAM, disk, network |

### Logs — Loki Stack
| Component | Role | Config |
|-----------|------|--------|
| Fluent Bit | Log collection + shipping | `fluent-bit-config.yaml` (DaemonSet) |
| Loki | Log aggregation + query | `loki-config.yaml` |
| Azure Log Analytics | SIEM / compliance | Diagnostic settings |

**Fluent Bit filters applied:**
1. Kubernetes metadata enrichment (namespace, pod, container labels)
2. Add cluster name + environment labels
3. Drop health check noise (`/healthz`, `/readyz`, `/livez`)
4. JSON log parsing

### Traces — OpenTelemetry Stack
| Component | Role | Config |
|-----------|------|--------|
| OTel Collector | Receive + process + export | `otel-config.yaml` |
| Tempo | Trace storage + query | `tempo-config.yaml` |
| Receivers | OTLP gRPC/HTTP, Jaeger, Zipkin | Ports: 4317, 4318, 14268, 6831 |
| Processors | Batch, k8sattributes, resource detection | Enrich all spans |
| Metrics Generator | Span → metrics (RED method) | Remote write to Prometheus |

### Grafana Dashboards
| Dashboard | UID | Data Sources | Key Panels |
|-----------|-----|-------------|-----------|
| Security Overview | `devsecops-security-overview` | Prometheus + Loki | Falco alerts, CVE counts, auth failures, cert expiry |
| SLO Dashboard | `devsecops-slo` | Prometheus | Availability, error rate, p50/90/99, burn rate, error budget |

### Alert Routing Policy
| Severity | Channel | Delay | Example |
|----------|---------|-------|---------|
| CRITICAL | PagerDuty | Immediate (30s) | Falco CRITICAL alert, service down |
| WARNING | OpsGenie | 15 min grouping | High CVE detected, cert expiring in 14d |
| INFO | Slack | 5 min grouping | Deployment success, scale events |

### SLO Targets
| Service | Availability | Latency (p99) | Error Rate |
|---------|-------------|---------------|-----------|
| API endpoints | 99.9% (43.8 min/month) | < 500ms | < 0.1% |
| Background jobs | 99.5% | < 5s | < 0.5% |

### Data Retention
| Store | Retention | Backend |
|-------|-----------|---------|
| Prometheus | 15 days (local) | Local disk |
| VictoriaMetrics | 1 year | Azure Blob |
| Loki | 30 days | Azure Blob |
| Tempo | 7 days | Azure Blob |
| Log Analytics | 90 days | Azure managed |
