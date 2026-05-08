data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Managed Identity
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace (Container Insights + Diagnostics)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = var.log_analytics_workspace_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = var.tags
}

resource "azurerm_log_analytics_solution" "container_insights" {
  solution_name         = "ContainerInsights"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}

# ---------------------------------------------------------------------------
# Key Vault (etcd encryption at rest with customer-managed key)
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                            = var.key_vault_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  tenant_id                       = var.tenant_id
  sku_name                        = var.key_vault_sku
  soft_delete_retention_days      = 90
  purge_protection_enabled        = true
  enable_rbac_authorization       = true
  public_network_access_enabled   = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }

  tags = var.tags
}

# Grant AKS managed identity permissions to read the encryption key
resource "azurerm_role_assignment" "aks_kv_crypto_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# Grant Terraform executor permission to manage keys (bootstrap only)
resource "azurerm_role_assignment" "terraform_kv_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "etcd" {
  name         = "aks-etcd-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA-HSM"
  key_size     = 4096

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P29D"
  }

  depends_on = [
    azurerm_role_assignment.terraform_kv_admin,
    azurerm_role_assignment.aks_kv_crypto_user,
  ]
}

# ---------------------------------------------------------------------------
# Azure Container Registry
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "main" {
  name                          = var.acr_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = var.acr_sku
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = true

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Allow AKS node pools to pull images from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ---------------------------------------------------------------------------
# AKS Cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "main" {
  name                              = var.cluster_name
  resource_group_name               = azurerm_resource_group.main.name
  location                          = azurerm_resource_group.main.location
  dns_prefix                        = var.dns_prefix
  kubernetes_version                = var.kubernetes_version
  node_resource_group               = "${var.resource_group_name}-nodes"
  private_cluster_enabled           = true
  private_cluster_public_fqdn_enabled = false
  sku_tier                          = "Standard"
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  local_account_disabled            = true
  http_application_routing_enabled  = false
  azure_policy_enabled              = true
  image_cleaner_enabled             = true
  image_cleaner_interval_hours      = 48

  api_server_access_profile {
    authorized_ip_ranges = var.authorized_ip_ranges
  }

  default_node_pool {
    name                         = var.system_node_pool_name
    vm_size                      = var.system_node_pool_vm_size
    zones                        = ["1"]
    enable_auto_scaling          = true
    min_count                    = var.system_node_pool_min_count
    max_count                    = var.system_node_pool_max_count
    only_critical_addons_enabled = true
    os_disk_size_gb              = 128
    os_disk_type                 = "Ephemeral"
    vnet_subnet_id               = var.vnet_subnet_id
    type                         = "VirtualMachineScaleSets"

    upgrade_settings {
      max_surge = "33%"
    }

    node_labels = {
      "nodepool-type" = "system"
      "environment"   = "production"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
    outbound_type     = "userDefinedRouting"
    load_balancer_sku = "standard"
  }

  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = var.aad_admin_group_object_ids
    tenant_id              = var.tenant_id
  }

  key_management_service {
    key_vault_key_id         = azurerm_key_vault_key.etcd.id
    key_vault_network_access = "Private"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  ingress_application_gateway {
    subnet_id = var.agic_subnet_id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  storage_profile {
    blob_driver_enabled         = true
    disk_driver_enabled         = true
    file_driver_enabled         = true
    snapshot_controller_enabled = true
  }

  auto_scaler_profile {
    balance_similar_node_groups      = true
    expander                         = "least-waste"
    max_graceful_termination_sec     = 600
    scale_down_delay_after_add       = "10m"
    scale_down_unneeded              = "10m"
    skip_nodes_with_system_pods      = true
  }

  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [1, 2, 3, 4]
    }
  }

  tags = var.tags

  depends_on = [
    azurerm_role_assignment.aks_kv_crypto_user,
    azurerm_key_vault_key.etcd,
  ]
}

# ---------------------------------------------------------------------------
# Additional Node Pools: App Zone B and Zone C
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "app_zone_b" {
  name                  = var.app_pool_b_name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.app_node_pool_vm_size
  zones                 = ["2"]
  enable_auto_scaling   = true
  min_count             = var.app_node_pool_min_count
  max_count             = var.app_node_pool_max_count
  os_disk_size_gb       = 128
  os_disk_type          = "Ephemeral"
  vnet_subnet_id        = var.vnet_subnet_id
  mode                  = "User"

  node_labels = {
    "nodepool-type"       = "application"
    "availability-zone"   = "2"
    "environment"         = "production"
  }

  node_taints = ["workload=application:NoSchedule"]

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "app_zone_c" {
  name                  = var.app_pool_c_name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.app_node_pool_vm_size
  zones                 = ["3"]
  enable_auto_scaling   = true
  min_count             = var.app_node_pool_min_count
  max_count             = var.app_node_pool_max_count
  os_disk_size_gb       = 128
  os_disk_type          = "Ephemeral"
  vnet_subnet_id        = var.vnet_subnet_id
  mode                  = "User"

  node_labels = {
    "nodepool-type"       = "application"
    "availability-zone"   = "3"
    "environment"         = "production"
  }

  node_taints = ["workload=application:NoSchedule"]

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Diagnostic Settings – route AKS control plane logs to Log Analytics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "${var.cluster_name}-diag"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "kube-audit" }
  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "guard" }
  enabled_log { category = "cluster-autoscaler" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
