# =============================================================================
# Module: aks — production-shaped AKS cluster
# =============================================================================
# Design decisions (see docs/DECISIONS.md):
#   ADR-001  Azure CNI Overlay + Cilium — pod IPs come from an overlay CIDR so
#            the spoke VNet does not need to be sized for pod density, and
#            Cilium gives eBPF NetworkPolicy without a sidecar tax.
#   ADR-004  Workload Identity (OIDC federation) replaces every secret-based
#            credential in the cluster. No service principal passwords exist.
#   ADR-005  Three-tier node pool topology: system pool tainted for platform
#            components only, a general app pool, and an optional spot pool for
#            interruptible batch work at ~70% lower cost.
#   ADR-007  Seasonal traffic: the cluster autoscaler is tuned to scale up fast
#            and down slowly, so a spike does not thrash the node pool.
# =============================================================================

locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "aks"
    environment = var.environment
  })

  # Production runs across all three zones; dev collapses to one to save cost.
  zones = var.environment == "prod" ? ["1", "2", "3"] : ["1"]
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-${local.name_prefix}-aks"
  location = var.location
  tags     = local.common_tags
}

# Control-plane identity. User-assigned so it survives cluster recreation and
# can be granted RBAC before the cluster exists.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "id-${local.name_prefix}-aks"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  tags                = local.common_tags
}

# The kubelet identity is what pulls images — it needs AcrPull, and nothing else.
resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-${local.name_prefix}-kubelet"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "cluster_identity_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# The control plane joins nodes to a pre-existing subnet it does not own.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.acr_id == "" ? 0 : 1

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
}

# ── Cluster ──────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.name_prefix}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "aks-${local.name_prefix}"
  node_resource_group = "rg-${local.name_prefix}-aks-nodes"

  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.environment == "prod" ? "Standard" : "Free"
  automatic_upgrade_channel = var.environment == "prod" ? "stable" : "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Private clusters keep the API server off the internet entirely. Runners
  # reach it through the self-hosted agent pool in the apps subnet.
  private_cluster_enabled             = var.private_cluster_enabled
  private_cluster_public_fqdn_enabled = false

  # When the cluster is NOT private (dev/staging), the API server still must not
  # be open to the whole internet: restrict it to the office/VPN ranges and the
  # NAT egress IP the runners come from. Terraform fails the plan rather than
  # silently exposing the endpoint if the list is empty (see the precondition).
  dynamic "api_server_access_profile" {
    for_each = var.private_cluster_enabled ? [] : [1]
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  lifecycle {
    precondition {
      condition = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) > 0
      error_message = join(" ", [
        "A public AKS API server must have api_server_authorized_ip_ranges set.",
        "Either set private_cluster_enabled = true or supply the CIDRs allowed to reach the control plane.",
      ])
    }

    ignore_changes = [
      # The autoscaler owns node counts at runtime; Terraform must not fight it.
      default_node_pool[0].node_count,
      # Patch versions drift via the auto-upgrade channel by design.
      kubernetes_version,
    ]
  }

  # Local accounts are the one credential that cannot be rotated or revoked
  # centrally — Entra ID + Kubernetes RBAC is the only supported path.
  local_account_disabled            = true
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  image_cleaner_enabled             = true
  image_cleaner_interval_hours      = 24

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_pool_vm_size
    vnet_subnet_id               = var.system_subnet_id
    zones                        = local.zones
    auto_scaling_enabled         = true
    min_count                    = var.system_pool_min_count
    max_count                    = var.system_pool_max_count
    max_pods                     = 60
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = 128
    only_critical_addons_enabled = true # taints the pool: platform components only
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge = "33%"
    }

    tags = local.common_tags
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = cidrhost(var.service_cidr, 10)
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
  }

  # Entra ID groups are the only way in; no cluster-admin certificates issued.
  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  # Secrets are mounted from Key Vault at runtime and rotated every 2 minutes;
  # nothing is materialised into a Kubernetes Secret at rest.
  # "2m" is a rotation interval, not a credential — the detect-secrets keyword
  # heuristic matches on the `secret_*` attribute name.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m" # pragma: allowlist secret
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }

  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  auto_scaler_profile {
    balance_similar_node_groups = true
    expander                    = "least-waste"
    # Scale up aggressively, scale down conservatively: during a seasonal spike
    # a premature scale-down costs far more (dropped traffic) than the idle
    # node it saves.
    scale_down_delay_after_add       = "15m"
    scale_down_unneeded              = "15m"
    scale_down_utilization_threshold = "0.5"
    max_graceful_termination_sec     = "600"
    skip_nodes_with_local_storage    = true
    skip_nodes_with_system_pods      = true
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Tuesday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Wednesday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  tags = local.common_tags
}

# ── Application node pool ────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.app_pool_vm_size
  vnet_subnet_id        = var.apps_subnet_id
  zones                 = local.zones
  auto_scaling_enabled  = true
  min_count             = var.app_pool_min_count
  max_count             = var.app_pool_max_count
  max_pods              = 110
  os_disk_type          = "Ephemeral"
  os_disk_size_gb       = 256
  mode                  = "User"

  node_labels = {
    "workload-type" = "application"
  }

  upgrade_settings {
    max_surge = "33%"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ── Spot pool for interruptible work ─────────────────────────────────────────
# Batch reconciliation and report generation tolerate eviction; running them on
# spot cuts that share of compute cost by roughly 70%. The taint means only
# workloads that explicitly tolerate eviction land here.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.spot_pool_vm_size
  vnet_subnet_id        = var.apps_subnet_id
  zones                 = local.zones
  auto_scaling_enabled  = true
  min_count             = 0
  max_count             = var.spot_pool_max_count
  max_pods              = 110
  mode                  = "User"
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1 # pay up to the on-demand price, never more

  node_labels = {
    "workload-type"                         = "batch"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]

  tags = local.common_tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ── Windows pool: the landing zone for lift-and-shift .NET Framework ─────────
# Legacy .NET Framework services cannot run on Linux. This pool lets them move
# off VMs onto the same control plane, scheduler and observability stack while
# they are being ported to .NET 10 (see docs/MIGRATION-DOTNET.md).
resource "azurerm_kubernetes_cluster_node_pool" "windows" {
  count = var.enable_windows_pool ? 1 : 0

  name                  = "win"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.windows_pool_vm_size
  vnet_subnet_id        = var.apps_subnet_id
  zones                 = local.zones
  auto_scaling_enabled  = true
  min_count             = var.windows_pool_min_count
  max_count             = var.windows_pool_max_count
  max_pods              = 60
  mode                  = "User"
  os_type               = "Windows"
  os_sku                = "Windows2022"

  node_labels = {
    "workload-type" = "legacy-dotnet-framework"
  }

  node_taints = ["os=windows:NoSchedule"]

  tags = local.common_tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ── Diagnostics ──────────────────────────────────────────────────────────────
# kube-audit is the control-plane evidence trail; without it there is no record
# of who changed what in a payment-handling cluster.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-aks-${local.name_prefix}"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_log {
    category = "guard"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
