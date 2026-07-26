# =============================================================================
# Environment: dev
# =============================================================================
# Dev optimises for iteration speed and cost, not fidelity. It is the only
# environment where a platform engineer can break things freely, so it runs the
# smallest viable footprint:
#
#   - 2-node system pool, 1-8 app nodes, single zone
#   - Serverless SQL that auto-pauses (near-zero cost overnight)
#   - Public endpoints, no private endpoints, no flow logs
#   - Free-tier AKS control plane (no uptime SLA)
#
# What it deliberately keeps identical to production: workload identity
# federation, RBAC model, GitOps flow, and the Helm charts. Those are where
# environment drift actually causes production incidents.
# =============================================================================

locals {
  environment = "dev"

  common_tags = {
    platform    = var.name_prefix
    environment = local.environment
    managed-by  = "terraform"
    cost-centre = var.cost_centre
    owner       = var.owning_team
    data-class  = "internal"
    # Picked up by a nightly automation that shuts dev down out of hours.
    auto-shutdown = "true"
  }
}

module "observability" {
  source = "../../modules/observability"

  name_prefix     = var.name_prefix
  environment     = local.environment
  location        = var.location
  subscription_id = var.subscription_id

  nonprod_daily_quota_gb = 2

  # Dev shares the staging Grafana; a third instance earns nobody anything.
  enable_managed_grafana = false

  # No alerting in dev: it would only ever be noise.
  enable_slo_alerts = false

  key_vault_id   = module.platform_identity.key_vault_id
  aks_cluster_id = module.aks.cluster_id

  tags = local.common_tags
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  environment = local.environment
  location    = var.location
  vnet_cidr   = var.vnet_cidr

  tags = local.common_tags
}

module "aks" {
  source = "../../modules/aks"

  name_prefix        = var.name_prefix
  environment        = local.environment
  location           = var.location
  kubernetes_version = var.kubernetes_version
  tenant_id          = var.tenant_id

  admin_group_object_ids = var.cluster_admin_group_object_ids

  vnet_id          = module.network.vnet_id
  system_subnet_id = module.network.subnet_ids["system"]
  apps_subnet_id   = module.network.subnet_ids["apps"]

  # Public endpoint, so the API server must be restricted to known ranges.
  private_cluster_enabled         = false
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges

  system_pool_vm_size   = "Standard_D2ds_v5"
  system_pool_min_count = 2
  system_pool_max_count = 3
  app_pool_vm_size      = "Standard_D4ds_v5"
  app_pool_min_count    = 1
  app_pool_max_count    = 8

  enable_spot_pool    = false
  enable_windows_pool = false

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}

module "platform_identity" {
  source = "../../modules/platform-identity"

  name_prefix   = var.name_prefix
  environment   = local.environment
  location      = var.location
  unique_suffix = var.unique_suffix
  tenant_id     = var.tenant_id

  oidc_issuer_url = module.aks.oidc_issuer_url
  aks_cluster_id  = module.aks.cluster_id

  data_subnet_id       = module.network.subnet_ids["data"]
  apps_subnet_id       = module.network.subnet_ids["apps"]
  private_dns_zone_ids = module.network.private_dns_zone_ids

  allowed_ip_ranges = var.allowed_ip_ranges

  key_vault_csi_identity_object_id = module.aks.key_vault_secrets_provider_identity
  platform_admin_group_object_ids  = var.platform_admin_group_object_ids

  workload_identities = {
    payments-api = {
      namespace       = "payments"
      service_account = "payments-api"
    }
    ledger-worker = {
      namespace       = "payments"
      service_account = "ledger-worker"
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }

  github_repository          = var.github_repository
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}

module "data" {
  source = "../../modules/data"

  name_prefix     = var.name_prefix
  environment     = local.environment
  location        = var.location
  unique_suffix   = var.unique_suffix
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  data_subnet_id       = module.network.subnet_ids["data"]
  apps_subnet_id       = module.network.subnet_ids["apps"]
  private_dns_zone_ids = module.network.private_dns_zone_ids

  database_name    = var.database_name
  nonprod_sku_name = "GP_S_Gen5_1"
  max_size_gb      = 32

  allowed_ip_ranges = var.allowed_ip_ranges

  sql_admin_group_name      = var.sql_admin_group_name
  sql_admin_group_object_id = var.sql_admin_group_object_id

  workload_principal_ids = [
    module.platform_identity.workload_identity_principal_ids["payments-api"],
    module.platform_identity.workload_identity_principal_ids["ledger-worker"],
  ]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}
