#!/usr/bin/env bash
# install-security-tools.sh — Install all DevSecOps security tools locally.
# Supports: macOS (brew) and Linux (apt/curl)
set -euo pipefail

OS="$(uname -s)"
ARCH="$(uname -m)"
TOOLS_DIR="${HOME}/.local/bin"
mkdir -p "${TOOLS_DIR}"

info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

install_or_skip() {
    local tool="$1"
    if command -v "${tool}" &>/dev/null; then
        warn "${tool} already installed: $(${tool} --version 2>/dev/null | head -1)"
    else
        return 1
    fi
}

# ── Trivy ─────────────────────────────────────────────────────────────────────
install_trivy() {
    install_or_skip trivy && return 0
    info "Installing Trivy..."
    TRIVY_VERSION="0.53.0"
    if [[ "${OS}" == "Darwin" ]]; then
        brew install aquasecurity/trivy/trivy
    else
        wget -qO- "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" | \
            tar -xz -C "${TOOLS_DIR}" trivy
    fi
    success "Trivy installed"
}

# ── Cosign ────────────────────────────────────────────────────────────────────
install_cosign() {
    install_or_skip cosign && return 0
    info "Installing cosign..."
    COSIGN_VERSION="2.2.4"
    if [[ "${OS}" == "Darwin" ]]; then
        brew install sigstore/tap/cosign
    else
        curl -sSL -o "${TOOLS_DIR}/cosign" \
            "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
        chmod +x "${TOOLS_DIR}/cosign"
    fi
    success "cosign installed"
}

# ── Syft (SBOM generator) ──────────────────────────────────────────────────────
install_syft() {
    install_or_skip syft && return 0
    info "Installing Syft..."
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | \
        sh -s -- -b "${TOOLS_DIR}"
    success "Syft installed"
}

# ── Grype (vulnerability scanner) ─────────────────────────────────────────────
install_grype() {
    install_or_skip grype && return 0
    info "Installing Grype..."
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | \
        sh -s -- -b "${TOOLS_DIR}"
    success "Grype installed"
}

# ── Semgrep ───────────────────────────────────────────────────────────────────
install_semgrep() {
    install_or_skip semgrep && return 0
    info "Installing Semgrep..."
    pip install semgrep --quiet
    success "Semgrep installed"
}

# ── Gitleaks ──────────────────────────────────────────────────────────────────
install_gitleaks() {
    install_or_skip gitleaks && return 0
    info "Installing Gitleaks..."
    GITLEAKS_VERSION="8.18.4"
    if [[ "${OS}" == "Darwin" ]]; then
        brew install gitleaks
    else
        wget -qO- "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" | \
            tar -xz -C "${TOOLS_DIR}" gitleaks
    fi
    success "Gitleaks installed"
}

# ── detect-secrets ────────────────────────────────────────────────────────────
install_detect_secrets() {
    install_or_skip detect-secrets && return 0
    info "Installing detect-secrets..."
    pip install detect-secrets --quiet
    success "detect-secrets installed"
}

# ── pre-commit ────────────────────────────────────────────────────────────────
install_pre_commit() {
    install_or_skip pre-commit && return 0
    info "Installing pre-commit..."
    pip install pre-commit --quiet
    success "pre-commit installed"
}

# ── Hadolint (Dockerfile linter) ──────────────────────────────────────────────
install_hadolint() {
    install_or_skip hadolint && return 0
    info "Installing Hadolint..."
    HADOLINT_VERSION="2.12.0"
    if [[ "${OS}" == "Darwin" ]]; then
        brew install hadolint
    else
        wget -qO "${TOOLS_DIR}/hadolint" \
            "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64"
        chmod +x "${TOOLS_DIR}/hadolint"
    fi
    success "Hadolint installed"
}

# ── kubectl + helm ────────────────────────────────────────────────────────────
install_kubectl_helm() {
    install_or_skip kubectl || {
        info "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl && mv kubectl "${TOOLS_DIR}/"
        success "kubectl installed"
    }
    install_or_skip helm || {
        info "Installing Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        success "Helm installed"
    }
}

# ── Azure CLI ─────────────────────────────────────────────────────────────────
install_azure_cli() {
    install_or_skip az && return 0
    info "Installing Azure CLI..."
    if [[ "${OS}" == "Darwin" ]]; then
        brew install azure-cli
    else
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    fi
    success "Azure CLI installed"
}

# ── Initialize secrets baseline ───────────────────────────────────────────────
init_secrets_baseline() {
    if [[ ! -f ".secrets.baseline" ]]; then
        info "Initializing detect-secrets baseline..."
        detect-secrets scan --all-files > .secrets.baseline
        success "Secrets baseline created: .secrets.baseline"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "Installing DevSecOps security tools..."
    echo ""

    install_azure_cli
    install_kubectl_helm
    install_trivy
    install_cosign
    install_syft
    install_grype
    install_semgrep
    install_gitleaks
    install_detect_secrets
    install_pre_commit
    install_hadolint

    # Add tools dir to PATH hint
    if [[ ":${PATH}:" != *":${TOOLS_DIR}:"* ]]; then
        warn "Add ${TOOLS_DIR} to your PATH: export PATH=\"\${PATH}:${TOOLS_DIR}\""
    fi

    echo ""
    info "Setting up pre-commit hooks..."
    pre-commit install --install-hooks
    pre-commit install --hook-type commit-msg

    init_secrets_baseline

    echo ""
    success "All security tools installed!"
    echo ""
    echo "Tool versions:"
    for tool in trivy cosign syft grype semgrep gitleaks hadolint kubectl helm az; do
        if command -v "${tool}" &>/dev/null; then
            echo "  ${tool}: $(${tool} version 2>/dev/null | head -1 || ${tool} --version 2>/dev/null | head -1)"
        fi
    done
}

main "$@"
