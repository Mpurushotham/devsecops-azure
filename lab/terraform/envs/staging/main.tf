# =============================================================================
# Environment: staging
# =============================================================================
# Staging exists to catch what dev cannot: real private networking, real
# workload identity, real GitOps promotion. It is production's topology at a
# fraction of the capacity — same shape, smaller numbers — because a staging
# environment that differs structurally from production validates nothing.
#
# Deliberate differences from prod, all cost-driven and all documented:
#   - Public cluster endpoint (no self-hosted runner needed to deploy)
#   - Single availability zone
#   - General Purpose serverless SQL, which auto-pauses when idle
#   - No spot or Windows pools
#   - 30-day log retention instead of 180
# =============================================================================

locals {
  environment = "staging"

  common_tags = {
    platform    = var.name_prefix
    environment = local.environment
    managed-by  = "terraform"
    cost-centre = var.cost_centre
    owner       = var.owning_team
    data-class  = "internal"
  }
}

module "observability" {
  source = "../../modules/observability"

  name_prefix     = var.name_prefix
  environment     = local.environment
  location        = var.location
  subscription_id = var.subscription_id

  nonprod_daily_quota_gb = 5

  enable_managed_grafana         = true
  grafana_admin_group_object_ids = var.platform_admin_group_object_ids

  # Staging alerts open tickets; they never page. A staging outage at 03:00 is
  # not a customer-impacting event.
  enable_slo_alerts  = true
  slo_p99_latency_ms = 1500

  slack_webhook_url = var.slack_webhook_url

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

  # Public endpoint: GitHub-hosted runners can reach it directly, so staging
  # does not need the self-hosted runner fleet production requires. It is still
  # restricted to known CIDRs — public does not mean open.
  private_cluster_enabled         = false
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges

  system_pool_min_count = 2
  system_pool_max_count = 3
  app_pool_vm_size      = "Standard_D4ds_v5"
  app_pool_min_count    = 2
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

  # Identical workload set to production: promotion must not surprise anyone.
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

  database_name = var.database_name
  # Serverless auto-pauses after an hour idle — staging costs nothing overnight.
  nonprod_sku_name = "GP_S_Gen5_2"
  max_size_gb      = 50

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
