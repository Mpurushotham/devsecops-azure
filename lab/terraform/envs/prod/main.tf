# =============================================================================
# Environment: prod
# =============================================================================
# Composition root. Modules are wired here and nowhere else — a module never
# reaches into another module's state, only through explicit outputs, so the
# dependency graph stays readable and any module can be tested in isolation.
#
# Apply order is derived automatically from these references:
#   observability -> network -> aks -> platform-identity -> data
#
# platform-identity depends on the AKS OIDC issuer, and data depends on the
# workload identity principals, so identity sits between cluster and database.
# =============================================================================

locals {
  environment = "prod"

  common_tags = {
    platform    = var.name_prefix
    environment = local.environment
    managed-by  = "terraform"
    cost-centre = var.cost_centre
    owner       = var.owning_team
    # Production data is in scope for payment-related audits; the tag drives
    # Azure Policy assignment and cost reporting.
    data-class = "confidential"
  }
}

# Observability comes first: every other module ships diagnostics into it.
module "observability" {
  source = "../../modules/observability"

  name_prefix     = var.name_prefix
  environment     = local.environment
  location        = var.location
  subscription_id = var.subscription_id

  prod_log_retention_days        = 180
  prod_trace_sampling_percentage = 10

  enable_managed_grafana         = true
  grafana_admin_group_object_ids = var.platform_admin_group_object_ids

  enable_slo_alerts        = true
  slo_fast_burn_error_rate = 0.05
  slo_slow_burn_error_rate = 0.01
  slo_p99_latency_ms       = 800

  pagerduty_webhook_url = var.pagerduty_webhook_url
  slack_webhook_url     = var.slack_webhook_url
  oncall_emails         = var.oncall_emails

  key_vault_id    = module.platform_identity.key_vault_id
  aks_cluster_id  = module.aks.cluster_id
  elastic_api_key = var.elastic_api_key
  datadog_api_key = var.datadog_api_key

  tags = local.common_tags
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  environment = local.environment
  location    = var.location
  vnet_cidr   = var.vnet_cidr

  # Flow logs are audit evidence for payment traffic, not optional in prod.
  enable_flow_logs             = var.enable_flow_logs
  network_watcher_name         = var.network_watcher_name
  flow_log_storage_account_id  = var.flow_log_storage_account_id
  flow_log_retention_days      = 90
  log_analytics_workspace_id   = module.observability.log_analytics_workspace_id
  log_analytics_workspace_guid = module.observability.log_analytics_workspace_guid

  tags = local.common_tags
}

module "aks" {
  source = "../../modules/aks"

  name_prefix        = var.name_prefix
  environment        = local.environment
  location           = var.location
  kubernetes_version = var.kubernetes_version
  tenant_id          = var.tenant_id

  # Break-glass only. Day-to-day access is namespace-scoped through GitOps.
  admin_group_object_ids = var.cluster_admin_group_object_ids

  vnet_id          = module.network.vnet_id
  system_subnet_id = module.network.subnet_ids["system"]
  apps_subnet_id   = module.network.subnet_ids["apps"]

  private_cluster_enabled = true

  # Peak capacity: sized from the last seasonal event plus 40% headroom.
  system_pool_min_count = 3
  system_pool_max_count = 6
  app_pool_vm_size      = "Standard_D8ds_v5"
  app_pool_min_count    = 5
  app_pool_max_count    = 30

  # Batch reconciliation runs on spot at ~70% lower cost.
  enable_spot_pool    = true
  spot_pool_max_count = 12

  # Landing zone for .NET Framework services still being ported (ADR-013).
  enable_windows_pool    = var.enable_windows_pool
  windows_pool_min_count = 2
  windows_pool_max_count = 8

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

  # One identity per workload, each pinned to a single namespace + SA pair.
  workload_identities = {
    payments-api = {
      namespace                = "payments"
      service_account          = "payments-api"
      key_vault_secrets_access = true
    }
    ledger-worker = {
      namespace                = "payments"
      service_account          = "ledger-worker"
      key_vault_secrets_access = true
    }
    external-secrets = {
      namespace                = "external-secrets"
      service_account          = "external-secrets"
      key_vault_secrets_access = true
    }
  }

  github_repository    = var.github_repository
  acr_geo_replications = var.acr_geo_replications

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
  prod_sku_name = "BC_Gen5_8"
  max_size_gb   = 500

  allowed_ip_ranges = var.allowed_ip_ranges

  sql_admin_group_name      = var.sql_admin_group_name
  sql_admin_group_object_id = var.sql_admin_group_object_id

  # Only the services that actually touch the database get an assignment.
  workload_principal_ids = [
    module.platform_identity.workload_identity_principal_ids["payments-api"],
    module.platform_identity.workload_identity_principal_ids["ledger-worker"],
  ]

  security_alert_emails      = var.oncall_emails
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}
