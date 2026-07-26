# Platform Architecture

How the pieces fit together, and where the boundaries are. Decisions and their
justifications live in [DECISIONS.md](./DECISIONS.md); this document describes
the resulting system.

---

## 1. The whole platform

```mermaid
flowchart TB
    subgraph dev["Developer"]
        D1[Feature branch]
        D2[Pull request]
    end

    subgraph ci["CI — GitHub Actions / Azure DevOps"]
        C1[Lint · test · build]
        C2["Security gates<br/>SAST · SCA · secrets · IaC"]
        C3["Container build<br/>SBOM + provenance"]
        C4["cosign sign<br/>Sigstore transparency log"]
    end

    subgraph acr["Azure Container Registry"]
        R1[(Signed image<br/>digest-pinned)]
    end

    subgraph git["Git — the source of truth"]
        G1[Terraform modules]
        G2[Helm charts]
        G3["Environment overlays<br/>image digests"]
    end

    subgraph aks["AKS — multi-zone"]
        A1["ArgoCD<br/>app-of-apps"]
        A2["Kyverno<br/>admission control"]
        A3["Workloads<br/>payments-api · workers"]
        A4["Ingress + WAF<br/>cert-manager TLS"]
        A5["KEDA / HPA<br/>autoscaling"]
    end

    subgraph data["Data plane — private endpoints only"]
        S1[(Azure SQL<br/>Entra auth)]
        S2[(Key Vault<br/>HSM-backed)]
        S3[(RabbitMQ)]
    end

    subgraph obs["Observability"]
        O1["OTel Collector<br/>tail sampling + scrubbing"]
        O2[App Insights<br/>traces]
        O3[Managed Prometheus<br/>+ Grafana]
        O4[Elastic / Kibana<br/>logs]
        O5["Alerts → PagerDuty<br/>SLO burn rate"]
    end

    D1 --> D2 --> C1 --> C2 --> C3 --> C4 --> R1
    C4 -.->|"opens PR<br/>updates digest"| G3
    G1 & G2 & G3 --> A1
    A1 -->|sync| A2 --> A3
    R1 -->|"pull by digest<br/>workload identity"| A3
    A4 --> A3
    A5 -.->|scales| A3
    A3 -->|"private endpoint<br/>no password"| S1
    A3 -->|CSI driver| S2
    A3 --> S3
    A3 -->|OTLP| O1
    O1 --> O2 & O3 & O4
    O3 --> O5

    classDef secure fill:#e8f4ea,stroke:#2d6a4f,stroke-width:2px
    classDef danger fill:#fdeaea,stroke:#a4161a,stroke-width:2px
    class S1,S2,S3,R1 secure
    class A2,C2,C4 danger
```

**The one thing to notice:** CI never talks to the cluster. It builds a signed
image and proposes a digest change in git; ArgoCD does the deploying. A
compromised pipeline can propose a change, not make one.

---

## 2. Network segmentation

```mermaid
flowchart LR
    subgraph internet["Internet"]
        U[Users]
        P[Payment processors]
    end

    subgraph vnet["Spoke VNet — 10.10.0.0/16"]
        subgraph sn1["snet-ingress · /20"]
            LB["Load balancer<br/>NGINX + ModSecurity"]
        end
        subgraph sn2["snet-aks-system · /20"]
            SYS["System node pool<br/>CoreDNS · metrics-server"]
        end
        subgraph sn3["snet-aks-apps · /18"]
            APP["App node pools<br/>+ spot + Windows"]
        end
        subgraph sn4["snet-data · /20"]
            PE["Private endpoints<br/>SQL · Key Vault · ACR · Blob"]
        end
        NAT["NAT gateway<br/>static egress IP"]
    end

    subgraph paas["Azure PaaS"]
        SQL[(Azure SQL)]
        KV[(Key Vault)]
        ACR[(ACR)]
    end

    U -->|"443 only"| LB
    LB -->|"8080"| APP
    APP --> PE
    PE -.->|private link| SQL & KV & ACR
    APP --> NAT -->|"allowlisted<br/>static IP"| P

    NAT -.->|"no inbound"| internet

    classDef nsg fill:#fff4e6,stroke:#e07a5f
    class sn1,sn2,sn3,sn4 nsg
```

Every subnet has a deny-by-default NSG. The data subnet additionally denies all
outbound internet traffic — a private endpoint has no reason to originate a
connection, and that rule is what turns a compromised database credential from
an exfiltration path into a dead end.

The NAT gateway exists because payment processors allowlist source IPs. Default
AKS egress uses ephemeral load-balancer addresses that change on scale events,
which would break the integration exactly when traffic is highest.

---

## 3. Identity — no long-lived secrets anywhere

```mermaid
sequenceDiagram
    participant GH as GitHub Actions
    participant EID as Entra ID
    participant ACR as Container Registry
    participant Pod as payments-api pod
    participant KV as Key Vault
    participant SQL as Azure SQL

    Note over GH,EID: Build time
    GH->>EID: OIDC token (repo + environment claim)
    EID-->>GH: Access token (~1h)
    GH->>ACR: Push image (AcrPush)

    Note over Pod,SQL: Runtime
    Pod->>EID: Projected SA token<br/>(system:serviceaccount:payments:payments-api)
    EID-->>Pod: Access token
    Pod->>KV: Read secret (Key Vault Secrets User)
    KV-->>Pod: Value, mounted via CSI
    Pod->>SQL: Connect (Active Directory Default)
    SQL-->>Pod: Session — no password ever existed
```

Three federation relationships replace three stored credentials. The federated
credential is pinned to one namespace and one service account name, so a
compromised pod in `staging` cannot assume the `prod` identity — the subject
claim will not match.

What remains in Key Vault is what genuinely must be stored: third-party API
keys and payment-processor credentials. Those are mounted by the CSI driver at
pod start and rotated on a 2-minute interval, never materialised as a
long-lived Kubernetes Secret.

---

## 4. Delivery flow

```mermaid
sequenceDiagram
    autonumber
    participant Dev
    participant CI as CI pipeline
    participant ACR
    participant Git
    participant Argo as ArgoCD
    participant K8s as AKS

    Dev->>CI: Push to main
    CI->>CI: Lint, test, SAST, SCA
    CI->>CI: Build image (SBOM + provenance)
    CI->>CI: Trivy scan — CVSS gate
    CI->>ACR: Push
    CI->>CI: cosign sign + attest SBOM
    CI->>Git: Commit digest (dev) / open PR (staging, prod)

    Note over Git,Argo: Human review for staging and prod
    Git->>Argo: Webhook
    Argo->>K8s: Sync
    K8s->>K8s: Kyverno admission check
    K8s->>ACR: Pull by digest (workload identity)
    K8s-->>Argo: Healthy
    Argo-->>CI: Rollout complete
    CI->>K8s: Smoke test — digest match + headers
```

Rollback is `git revert`. There is no separate rollback procedure to remember
or test, because the forward and backward paths are the same mechanism.

---

## 5. Autoscaling under seasonal load

Rebtel's traffic is spiky around key calling seasons. Four layers respond at
different timescales:

```mermaid
flowchart TB
    T["Traffic spike"] --> K
    subgraph layers["Response layers, fastest first"]
        K["KEDA — queue depth<br/>~15s, predictive"]
        H["HPA — CPU/memory<br/>~30s, reactive"]
        C["Cluster autoscaler — pending pods<br/>~90s, adds nodes"]
        O["Overprovisioning pods<br/>instant, pre-warmed capacity"]
    end
    K --> H --> C
    O -.->|"evicted first,<br/>freeing warm nodes"| C
```

The ordering matters. CPU is a *lagging* indicator for an IO-bound API: by the
time CPU rises, requests are already queuing. KEDA scaling on RabbitMQ queue
depth reacts before the pods are saturated, and the cluster autoscaler is tuned
to scale up fast (`scale_down_delay_after_add = 15m`) so a spike does not cause
node thrash.

| Knob | Value | Why |
|---|---|---|
| `scaleUp.stabilizationWindowSeconds` | 0 | React immediately; a spike is not noise |
| `scaleUp` policy | +100% or +4 pods / 30s | Double capacity per interval |
| `scaleDown.stabilizationWindowSeconds` | 300 | Avoid a sawtooth after the peak |
| `scaleDown` policy | −25% / 60s | Give back capacity gradually |
| App pool `min_count` (prod) | 5 | Floor absorbs the spike before autoscaling |
| `maxUnavailable` on rollout | 0 | Never lose capacity mid-deploy |
| PDB `minAvailable` | 66% | A node drain cannot take the service down |

---

## 6. Observability signal routing

```mermaid
flowchart LR
    subgraph app["Every service"]
        SDK["OTel SDK<br/>traces · metrics · logs"]
    end

    COL["OTel Collector"]

    subgraph pol["Collector policy"]
        SCRUB["Scrub<br/>auth headers, SQL text, PAN, email"]
        TAIL["Tail sample<br/>100% errors + slow + payments<br/>5% of the rest"]
    end

    subgraph stores["Backends"]
        AI["App Insights<br/>traces · 90d"]
        PROM["Managed Prometheus<br/>metrics"]
        ELK["Elastic / Kibana<br/>logs · searchable"]
        LAW["Log Analytics<br/>audit · 180d · immutable"]
    end

    GRAF["Grafana<br/>single query surface"]
    PD["PagerDuty"]

    SDK -->|OTLP| COL --> SCRUB --> TAIL
    TAIL --> AI
    COL --> PROM
    COL --> ELK
    AKS["AKS control plane<br/>kube-audit"] --> LAW

    AI & PROM & ELK & LAW --> GRAF
    PROM -->|"SLO burn rate"| PD

    classDef scrub fill:#fdeaea,stroke:#a4161a
    class SCRUB scrub
```

Head sampling at 10% would discard 90% of errors — precisely the traces anyone
wants during an incident. Tail sampling keeps every error, every request slower
than 1s, and every payment flow, then samples the boring successful traffic at
5%. Cost falls without the diagnostic value falling with it.

Scrubbing happens at the collector, not in each service. A service that logs
too much is then contained by platform configuration rather than by a code fix
in someone else's repository.

---

## 7. Alerting philosophy

```mermaid
flowchart TB
    subgraph page["Pages a human — customers affected now"]
        P1["Fast burn: 14.4x error budget<br/>over 1h"]
        P2["Availability below SLO"]
    end
    subgraph ticket["Opens a ticket — degradation"]
        T1["Slow burn: 6x over 6h"]
        T2["p99 latency above target"]
        T3["HIGH CVE in a running image"]
        T4["Certificate expiring in 14d"]
    end
    subgraph log["Logged only"]
        L1["CPU / memory utilisation"]
        L2["Pod restarts within budget"]
        L3["MEDIUM and LOW CVEs"]
    end
```

CPU utilisation never pages. A service at 90% CPU that is serving every request
within its latency objective is a service that is correctly sized; waking
someone for it trains them to ignore alerts, which is how the real page gets
missed.

---

## 8. Repository layout

```
lab/
├── terraform/
│   ├── bootstrap/          Remote state + OIDC federation (run once)
│   ├── modules/
│   │   ├── network/            VNet, subnets, NSGs, NAT, private DNS
│   │   ├── aks/                Cluster, node pools, autoscaler, workload identity
│   │   ├── platform-identity/  ACR, Key Vault, federated credentials
│   │   ├── data/               Azure SQL, platform storage
│   │   └── observability/      Log Analytics, App Insights, Prometheus, alerts
│   └── envs/{dev,staging,prod}/  Composition roots
├── charts/dotnet-service/  The platform contract as a Helm chart
├── apps/payments-api/      Reference .NET 10 workload
├── kubernetes/
│   ├── apps/               ArgoCD projects, app-of-apps, environment overlays
│   └── platform/           Namespaces, OTel collector
├── azure-pipelines/        Azure DevOps equivalent of the GitHub workflows
├── scripts/                Security-contract assertions
├── docs/                   This file, DECISIONS.md, RUNBOOKS.md, MIGRATION-DOTNET.md
└── Makefile                Every CI check, runnable locally
```
