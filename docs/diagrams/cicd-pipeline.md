# Secure CI/CD Pipeline — Architecture

```mermaid
flowchart TD
    subgraph DEV["👨‍💻 Developer Workstation"]
        direction LR
        GC[Git Commit] --> |pre-commit hooks| PC{{"🔒 Pre-commit\ndetect-secrets\ngitleaks"}}
        PC --> PR[Pull Request]
    end

    subgraph PR_REVIEW["🔍 PR Security Review (Security Gates Workflow)"]
        direction TB
        SG1{{"🔍 gitleaks\nFull history scan"}}
        SG2{{"📊 Semgrep\nOWASP Top-10"}}
        SG3{{"🐍 Bandit\nPython SAST"}}
        SG4{{"📦 Trivy SCA\nDependency scan"}}
        SG5{{"🤫 TruffleHog3\nDeep secret scan"}}
        SG6{{"📜 FOSSA\nLicense compliance"}}
        SG7{{"📋 Syft SBOM\nCycloneDX"}}
        GATE{{"✅ Security Gate\n(all must pass)"}}
        SG1 & SG2 & SG3 & SG4 & SG5 & SG6 & SG7 --> GATE
    end

    subgraph CI["⚙️ CI Stage (on: push to main)"]
        direction TB
        LINT["Lint & Format\n(ESLint, flake8, black)"]
        BUILD["Build\n(reproducible, pinned deps)"]
        TEST["Unit + Integration Tests\n(JaCoCo coverage)"]
        SONAR["SonarQube\n(quality gate)"]
        LINT --> BUILD --> TEST --> SONAR
    end

    subgraph SEC["🛡️ Security Pipeline"]
        direction LR
        SAST{{"SAST\nSemgrep + SonarQube"}}
        SCA{{"SCA\nTrivy + Snyk"}}
        IMGBUILD["Container Image Build\n(multi-stage, pinned)"]
        IMGSCAN{{"Image Scan\nTrivy + Grype"}}
        DAST{{"DAST\nOWASP ZAP + Nuclei"}}

        SAST --> SCA --> IMGBUILD --> IMGSCAN --> DAST

        subgraph CVSS["CVSS Threshold Policy"]
            C1["≥ 9.0 → ❌ Block build"]
            C2["7.0-8.9 → ⚠️ Warn + Ticket"]
            C3["< 7.0 → 📝 Log only"]
        end
        IMGSCAN -.-> CVSS
        DAST -.-> CVSS
    end

    subgraph SIGN["🔏 Artifact Signing"]
        direction TB
        COSIGN["cosign sign\n(keyless OIDC)"]
        SBOM["Syft SBOM\n(CycloneDX + SPDX)"]
        SLSA["SLSA Provenance\n(Level 3)"]
        COSIGN --> SBOM --> SLSA
    end

    subgraph DEPLOY["🚀 Deploy"]
        direction TB
        STAGE["Staging Deploy\n(ArgoCD sync)"]
        SMOKE["Smoke Tests"]
        GATE2{{"Manual Approval Gate\n(sec-critical environments)"}}
        PROD["Production Deploy\n(Blue/Green, ArgoCD)"]
        VERIFY["cosign verify\n(before production)"]
        STAGE --> SMOKE --> GATE2 --> VERIFY --> PROD
    end

    PR --> |approved + security gates pass| CI
    CI --> SEC
    SEC --> |all scans pass| SIGN
    SIGN --> DEPLOY

    classDef security fill:#c0392b,color:#fff,stroke:#922b21
    classDef ok fill:#1a5276,color:#fff,stroke:#154360
    classDef gate fill:#117a65,color:#fff,stroke:#0e6655
    classDef warn fill:#b7950b,color:#fff,stroke:#9a7d0a

    class SG1,SG2,SG3,SG4,SG5,SG6,SG7,SAST,SCA,IMGSCAN,DAST security
    class BUILD,LINT,TEST,IMGBUILD ok
    class GATE,GATE2 gate
    class PC warn
```

## CVSS Threshold Policy

| Severity | CVSS Score | Action |
|----------|-----------|--------|
| Critical | ≥ 9.0 | **Block build immediately** — PR cannot merge |
| High | 7.0 – 8.9 | **Warn + auto-create GitHub Issue** — must fix within 7 days |
| Medium | 4.0 – 6.9 | **Log only** — track in vulnerability backlog |
| Low | < 4.0 | **Informational** — review at next sprint |

## Key Tool Mapping

| Pipeline Stage | Primary Tool | Secondary Tool | Output |
|---------------|-------------|----------------|--------|
| Secret detection | gitleaks | detect-secrets, TruffleHog3 | SARIF → GitHub Security |
| SAST | Semgrep (OWASP) | Bandit (Python), SonarQube | SARIF + Quality Gate |
| SCA | Trivy (filesystem) | Snyk | SARIF → GitHub Security |
| Image scan | Trivy (image) | Grype | SARIF → GitHub Security |
| DAST | OWASP ZAP | Nuclei | HTML report + SARIF |
| SBOM | Syft (CycloneDX) | Syft (SPDX) | Attached to release |
| Signing | cosign (keyless) | SLSA provenance | Attestation in ACR |
