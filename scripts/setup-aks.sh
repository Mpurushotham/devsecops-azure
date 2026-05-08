#!/usr/bin/env bash
# setup-aks.sh — Bootstrap AKS cluster with all DevSecOps components.
# Usage: ./scripts/setup-aks.sh [--env staging|production] [--dry-run]
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV="${1:-staging}"
DRY_RUN="${DRY_RUN:-false}"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

# ── Prerequisites check ────────────────────────────────────────────────────────
check_prereqs() {
    info "Checking prerequisites..."
    local tools=(az kubectl helm terraform cosign)
    for tool in "${tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            error "Required tool '${tool}' not found. Run scripts/install-security-tools.sh first."
        fi
    done
    success "All prerequisites found"
}

# ── Azure login ────────────────────────────────────────────────────────────────
azure_login() {
    info "Checking Azure login status..."
    if ! az account show &>/dev/null; then
        run az login --use-device-code
    fi
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    info "Using subscription: ${SUBSCRIPTION_ID}"
}

# ── Terraform apply ────────────────────────────────────────────────────────────
provision_infrastructure() {
    info "Provisioning AKS infrastructure via Terraform..."
    cd "${REPO_ROOT}/infrastructure/terraform/aks"

    run terraform init -upgrade
    run terraform validate

    if [[ "${DRY_RUN}" == "true" ]]; then
        run terraform plan -var="environment=${ENV}" -out=tfplan
    else
        run terraform plan -var="environment=${ENV}" -out=tfplan
        run terraform apply -auto-approve tfplan
    fi

    # Extract outputs
    AKS_CLUSTER_NAME=$(terraform output -raw cluster_fqdn | cut -d. -f1)
    RESOURCE_GROUP=$(terraform output -raw node_resource_group | sed 's/MC_//' | cut -d_ -f1)
    ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)

    export AKS_CLUSTER_NAME RESOURCE_GROUP ACR_LOGIN_SERVER
    success "Infrastructure provisioned: ${AKS_CLUSTER_NAME}"
    cd "${REPO_ROOT}"
}

# ── AKS credentials ────────────────────────────────────────────────────────────
get_aks_credentials() {
    info "Getting AKS credentials..."
    run az aks get-credentials \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${AKS_CLUSTER_NAME}" \
        --overwrite-existing
    run kubectl config use-context "${AKS_CLUSTER_NAME}"
    success "AKS context set"
}

# ── Install cert-manager ───────────────────────────────────────────────────────
install_cert_manager() {
    info "Installing cert-manager..."
    run helm repo add jetstack https://charts.jetstack.io --force-update
    run helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.15.0 \
        --set installCRDs=true \
        --set global.leaderElection.namespace=cert-manager \
        --wait

    info "Applying ClusterIssuers..."
    run kubectl apply -f "${REPO_ROOT}/kubernetes/cert-manager/cluster-issuer.yaml"
    success "cert-manager installed"
}

# ── Install Istio ──────────────────────────────────────────────────────────────
install_istio() {
    info "Installing Istio service mesh..."
    if ! command -v istioctl &>/dev/null; then
        warn "istioctl not found, installing..."
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.22.0 sh -
        export PATH="${PWD}/istio-1.22.0/bin:${PATH}"
    fi

    run istioctl install --set profile=production \
        --set values.pilot.resources.requests.cpu=200m \
        --set values.pilot.resources.requests.memory=256Mi \
        -y

    # Enable sidecar injection for app namespaces
    run kubectl label namespace production istio-injection=enabled --overwrite
    run kubectl label namespace staging istio-injection=enabled --overwrite

    run kubectl apply -f "${REPO_ROOT}/kubernetes/service-mesh/istio/"
    success "Istio installed"
}

# ── Install Kyverno ────────────────────────────────────────────────────────────
install_kyverno() {
    info "Installing Kyverno admission controller..."
    run helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
    run helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --create-namespace \
        --version 3.2.0 \
        --set admissionController.replicas=3 \
        --set backgroundController.enabled=true \
        --set cleanupController.enabled=true \
        --wait

    info "Applying Kyverno policies..."
    run kubectl apply -f "${REPO_ROOT}/kubernetes/security/kyverno/policies/"
    success "Kyverno installed with policies"
}

# ── Install Falco ──────────────────────────────────────────────────────────────
install_falco() {
    info "Installing Falco runtime security..."
    run helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
    run helm upgrade --install falco falcosecurity/falco \
        --namespace security \
        --create-namespace \
        --version 4.3.0 \
        --set driver.kind=ebpf \
        --set falcosidekick.enabled=true \
        --set falcosidekick.config.grafana.hostport="http://grafana.monitoring:3000" \
        --set falcosidekick.config.alertmanager.hostport="http://alertmanager.monitoring:9093" \
        --set falcosidekick.config.loki.hostport="http://loki.monitoring:3100" \
        --wait

    run kubectl apply -f "${REPO_ROOT}/kubernetes/security/falco/"
    success "Falco installed with custom rules"
}

# ── Install monitoring stack ───────────────────────────────────────────────────
install_monitoring() {
    info "Installing monitoring stack (Prometheus + Grafana + Loki + Tempo)..."

    run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    run helm repo add grafana https://grafana.github.io/helm-charts --force-update
    run helm repo update

    # kube-prometheus-stack (Prometheus + Alertmanager + Grafana)
    run helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --version 60.0.0 \
        --set prometheus.prometheusSpec.remoteWrite[0].url="http://victoria-metrics.monitoring:8428/api/v1/write" \
        --set grafana.enabled=true \
        --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD:-changeme}" \
        --wait

    # Loki
    run helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        --version 6.7.0 \
        -f "${REPO_ROOT}/observability/loki/loki-config.yaml" \
        --wait

    # Tempo
    run helm upgrade --install tempo grafana/tempo \
        --namespace monitoring \
        --version 1.10.0 \
        --wait

    # Apply custom configs and dashboards
    run kubectl apply -f "${REPO_ROOT}/observability/prometheus/"
    run kubectl apply -f "${REPO_ROOT}/observability/alertmanager/"
    run kubectl apply -f "${REPO_ROOT}/observability/otel-collector/"
    run kubectl apply -f "${REPO_ROOT}/observability/fluent-bit/"

    # Import Grafana dashboards
    for dashboard in "${REPO_ROOT}/observability/grafana/dashboards/"*.json; do
        dashboard_name=$(basename "${dashboard}" .json)
        info "Importing Grafana dashboard: ${dashboard_name}"
        kubectl create configmap "grafana-dashboard-${dashboard_name}" \
            --from-file="${dashboard}" \
            --namespace monitoring \
            --dry-run=client -o yaml | \
            kubectl label --local -f - grafana_dashboard=1 -o yaml | \
            run kubectl apply -f -
    done
    success "Monitoring stack installed"
}

# ── Install ArgoCD ─────────────────────────────────────────────────────────────
install_argocd() {
    info "Installing ArgoCD..."
    run helm repo add argo https://argoproj.github.io/argo-helm --force-update
    run helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --version 7.3.0 \
        --set server.insecure=false \
        --set configs.params."server\.insecure"=false \
        --wait

    run kubectl apply -f "${REPO_ROOT}/kubernetes/argocd/"
    success "ArgoCD installed"
}

# ── Apply network policies ─────────────────────────────────────────────────────
apply_network_policies() {
    info "Applying network policies..."
    run kubectl apply -f "${REPO_ROOT}/kubernetes/security/network-policies/"
    run kubectl apply -f "${REPO_ROOT}/kubernetes/base/"
    success "Network policies applied"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Azure DevSecOps — AKS Bootstrap (env: ${ENV})       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_prereqs
    azure_login
    provision_infrastructure
    get_aks_credentials
    apply_network_policies
    install_cert_manager
    install_istio
    install_kyverno
    install_falco
    install_monitoring
    install_argocd

    echo ""
    success "AKS cluster bootstrapped successfully!"
    info "Cluster: ${AKS_CLUSTER_NAME}"
    info "ACR: ${ACR_LOGIN_SERVER}"
    info "ArgoCD UI: $(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    info "Grafana UI: $(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
}

main "$@"
