# DevSecOps Security Gates — Shift-Left Architecture

```mermaid
flowchart LR
    subgraph SHIFT["Shift-Left Security — Gates at Every Stage"]
        direction LR
        CODE["📝 Code\nPre-commit hooks"]
        PR_REV["🔍 PR / Review\nSigned commits"]
        BUILD_S["🏗️ Build\nSecrets scan"]
        TEST_S["🧪 Test\nSAST / DAST"]
        RELEASE_S["📦 Release\nSign + SBOM"]
        RUNTIME["⚡ Runtime\nFalco, SIEM"]

        CODE --> PR_REV --> BUILD_S --> TEST_S --> RELEASE_S --> RUNTIME
    end

    subgraph BREAK["Break Build on Critical CVE"]
        direction TB
        CRITICAL["CVSS ≥ 9.0\n❌ BLOCK"]
        HIGH["CVSS 7.0-8.9\n⚠️ WARN + TICKET"]
        MEDIUM["CVSS < 7.0\n📝 LOG ONLY"]
    end

    BUILD_S -.->|"Critical CVE"| BREAK

    subgraph CONTROLS["Security Controls at Each Gate"]
        direction TB

        subgraph PRECOMMIT["Pre-commit"]
            direction TB
            PC1["detect-secrets"]
            PC2["gitleaks"]
        end

        subgraph SAST_BOX["SAST"]
            direction TB
            S1["SonarQube"]
            S2["Semgrep"]
            S3["Bandit"]
        end

        subgraph SCA_BOX["SCA"]
            direction TB
            SC1["Trivy"]
            SC2["Snyk"]
            SC3["SBOM generation"]
        end

        subgraph ADMISSION["Admission"]
            direction TB
            A1["Kyverno / OPA"]
            A2["Image policy"]
        end

        subgraph RUNTIME_BOX["Runtime"]
            direction TB
            R1["Falco rules"]
            R2["Audit → SIEM"]
        end
    end

    CODE --- PRECOMMIT
    PR_REV --- SAST_BOX
    BUILD_S --- SCA_BOX
    RELEASE_S --- ADMISSION
    RUNTIME --- RUNTIME_BOX

    subgraph GOVERNANCE["Compliance & Governance Controls"]
        direction LR
        G1["SBOM\nCycloneDX / SPDX"]
        G2["SLSA attestation\nSupply chain proof"]
        G3["cert-manager\nTLS, auto-renewal"]
        G4["Vuln management\nSLA, tracking, triage"]
    end

    classDef red fill:#c0392b,color:#fff,stroke:#922b21
    classDef orange fill:#d35400,color:#fff,stroke:#ba4a00
    classDef blue fill:#1a5276,color:#fff,stroke:#154360
    classDef green fill:#117a65,color:#fff,stroke:#0e6655
    classDef gray fill:#566573,color:#fff,stroke:#424949

    class CODE,PR_REV,BUILD_S,TEST_S,RELEASE_S blue
    class RUNTIME green
    class PC1,PC2,S1,S2,S3,SC1,SC2,SC3,A1,A2,R1,R2 red
    class CRITICAL red
    class HIGH orange
    class MEDIUM gray
    class G1,G2,G3,G4 gray
```

## Security Gate Details

### Stage 1: Code (Pre-commit)
| Check | Tool | Fail Action |
|-------|------|------------|
| Hardcoded secrets | detect-secrets | Block commit |
| Git history secrets | gitleaks | Block commit |
| Private keys | detect-secrets (regex) | Block commit |
| Azure credential patterns | gitleaks (custom rules) | Block commit |

### Stage 2: PR / Review (Security Gates Workflow)
| Check | Tool | Threshold |
|-------|------|-----------|
| SAST — multi-language | Semgrep (OWASP Top-10, CWE-25) | ERROR level → block |
| SAST — Python | Bandit (HIGH/HIGH) | Block |
| SCA — dependencies | Trivy filesystem | CRITICAL → block |
| Deep secret scan | TruffleHog3 (verified only) | Any → block |
| License compliance | FOSSA | Policy violation → block |
| SBOM generation | Syft (CycloneDX + SPDX) | Always generate |

### Stage 3: Build (Secrets Scan)
| Check | Tool | Action |
|-------|------|--------|
| Dockerfile lint | Hadolint | WARNING → fail |
| IaC scan | Trivy config, terraform tflint | CRITICAL → fail |
| Dependency SBOM | Syft | Attach to artifact |

### Stage 4: Test (SAST / DAST)
| Check | Tool | Action |
|-------|------|--------|
| Code quality gate | SonarQube | Quality gate fail → block |
| DAST full scan | OWASP ZAP | High alert → warn |
| CVE scanning | Nuclei | Critical → block |
| Image scan | Trivy image + Grype | CRITICAL → block |

### Stage 5: Release (Sign + SBOM)
| Check | Tool | Action |
|-------|------|--------|
| Image signing | cosign (keyless OIDC) | Required |
| SBOM generation | Syft | CycloneDX + SPDX |
| SLSA provenance | slsa-github-generator | Level 3 |
| Pre-deploy verify | cosign verify | Block if unverified |

### Stage 6: Runtime (Falco + SIEM)
| Rule | Severity | MITRE |
|------|----------|-------|
| Shell in container | CRITICAL | T1059 |
| Sensitive file write | CRITICAL | T1098 |
| Unexpected outbound | WARNING | T1071 |
| Setuid execution | CRITICAL | T1548 |
| Container drift | CRITICAL | T1611 |
| Crypto mining | CRITICAL | T1496 |
| K8s API from pod | CRITICAL | T1613 |
