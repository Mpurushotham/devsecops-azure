# AKS Kubernetes Platform — Security Architecture

```mermaid
graph TB
    subgraph AZURE["Azure Subscription"]
        subgraph AKS["AKS Cluster (Multi-Zone)"]
            subgraph CP["Control Plane (Managed by Azure)"]
                direction LR
                API["API Server"]
                ETCD["etcd\n(encrypted, CMK)"]
                CM["Controller\nManager"]
                SCHED["Scheduler"]
            end

            subgraph NP["Node Pools"]
                direction LR
                NPA["Node Pool\nZone A\n(System pods)"]
                NPB["Node Pool\nZone B\n(App pods)"]
                NPC["Node Pool\nZone C\n(App pods)"]
            end

            subgraph NET["Networking Layer"]
                direction LR
                INGRESS["Ingress Controller\nAGIC / NGINX + TLS"]
                MESH["Service Mesh\nIstio mTLS, policies"]
                NETPOL["Network Policies\nDeny-all"]
            end

            subgraph SEC["Security Layer"]
                direction LR
                KYV["Kyverno / OPA\nAdmission policies"]
                FALCO["Falco\nRuntime detection"]
                DEFENDER["Defender for Containers\nThreat detection"]
            end

            CP --> NP
            NP --> NET
            NET --> SEC
        end

        subgraph IDENTITY["Identity & Secrets"]
            MI["Managed Identity\n(Workload Identity)"]
            KV["Azure Key Vault\n(etcd CMK, secrets)"]
            ACR["Azure Container Registry\n(private, zone-redundant)"]
        end

        subgraph MONITOR["Monitoring & Audit"]
            LA["Log Analytics\n90-day retention"]
            SENTINEL["Azure Sentinel\n(SIEM)"]
            DEFENDER_CLOUD["Defender for Cloud\n(Standard tier)"]
        end
    end

    CP -.->|OIDC| MI
    KYV -.->|validate images| ACR
    FALCO -->|audit logs| LA
    LA --> SENTINEL
    DEFENDER --> DEFENDER_CLOUD

    classDef azure fill:#0078d4,color:#fff,stroke:#005a9e
    classDef security fill:#c0392b,color:#fff,stroke:#922b21
    classDef green fill:#117a65,color:#fff,stroke:#0e6655
    classDef gray fill:#566573,color:#fff,stroke:#424949

    class CP,API,ETCD,CM,SCHED azure
    class NPA,NPB,NPC green
    class KYV,FALCO,DEFENDER,DEFENDER_CLOUD,SENTINEL security
    class INGRESS,MESH,NETPOL,MI,KV,ACR,LA gray
```

## Security Controls Detail

### Control Plane Hardening
| Control | Implementation | Reference |
|---------|---------------|-----------|
| etcd encryption | Azure Key Vault CMK (RSA-HSM 4096) | CIS AKS 1.x |
| API server access | Private cluster + authorized IP ranges | CIS AKS 1.x |
| RBAC | AAD-integrated, Azure RBAC | CIS AKS 1.x |
| Local accounts | Disabled (`local_account_disabled = true`) | CIS AKS 1.x |
| OIDC issuer | Enabled (for Workload Identity) | Microsoft Best Practice |

### Node Pool Security
| Control | Implementation |
|---------|---------------|
| OS | Ephemeral OS disks (no persistent attack surface) |
| Auto-patching | Maintenance window: Sunday 01:00-04:00 UTC |
| Image Cleaner | Every 48h (remove unused images) |
| Node taints | `workload=application:NoSchedule` on app pools |
| Auto-scaling | Min 2 / Max 10 per zone, least-waste expander |

### Admission Policies (Kyverno)
| Policy | Mode | What It Enforces |
|--------|------|-----------------|
| disallow-privileged | Enforce | No privileged, hostPID, hostIPC, hostNetwork |
| require-image-digest | Enforce | SHA digest required in production (no `:latest`) |
| restrict-registries | Enforce | Only `myacr.azurecr.io` and `mcr.microsoft.com` |
| require-resource-limits | Enforce | CPU + memory requests/limits on all containers |
| require-non-root | Enforce | runAsNonRoot, drop ALL caps, readOnlyRootFilesystem |

### Network Policies
| Policy | Namespaces | Effect |
|--------|-----------|--------|
| default-deny-all | production, staging | Block all ingress + egress |
| allow-from-istio-ingress | production | Allow gateway → app:8080 |
| allow-prometheus-scrape | production | Allow monitoring ns → app:8080/metrics |
| allow-egress-dns | production, staging | Allow egress port 53 |
| allow-egress-monitoring | production | Allow egress to Loki (3100), OTel (4317/4318) |

### Istio Service Mesh
| Resource | Config | Effect |
|----------|--------|--------|
| PeerAuthentication | STRICT (production) | Mandatory mTLS for all pod-to-pod traffic |
| PeerAuthentication | PERMISSIVE (staging) | mTLS enabled but not required |
| AuthorizationPolicy | deny-all (default) | Block all traffic not explicitly allowed |
| AuthorizationPolicy | allow-ingress-to-app | SPIFFE principal-based ingress allow |
| DestinationRule | ISTIO_MUTUAL | Enforce mTLS for outbound connections |

### TLS Certificate Management
| Issuer | Use Case | Renewal |
|--------|---------|---------|
| letsencrypt-production | External HTTPS (app.example.com) | Auto (DNS-01 via Azure DNS) |
| letsencrypt-staging | Testing/non-prod | Auto |
| internal-ca | Internal service mTLS | Auto (cert-manager) |
