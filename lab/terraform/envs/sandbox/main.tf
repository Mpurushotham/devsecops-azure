# =============================================================================
# Environment: sandbox — a real deployment on a quota-constrained subscription
# =============================================================================
# This exists to prove the modules actually apply against live Azure, on an
# account with a 4 vCPU regional quota and a real bill. It is the same module
# set as dev/staging/prod, so what is exercised here is the production code
# path — only the sizing and the cost-bearing options differ.
#
# The 4 vCPU budget is the binding constraint and it dictates the topology:
#
#   2 x Standard_B2s  =  4 vCPU  =  the entire quota
#
# That leaves no room for a separate application pool, so the cluster runs a
# single untainted pool. Everything else is chosen to keep the bill near the
# floor while still being recognisably the same platform:
#
#   disabled here          why                              ~monthly cost avoided
#   ─────────────────────  ───────────────────────────────  ────────────────────
#   NAT gateway            static egress IP (ADR-003)       ~EUR 32 + data
#   Private endpoints      SQL/KV/ACR off the internet      ~EUR 7 per endpoint
#   Private DNS zones      resolution for the above         ~EUR 0.45 per zone
#   Azure SQL              the app can run without it        ~EUR 5-15
#   Managed Grafana        dashboards                        ~EUR 45
#   Defender for Containers runtime threat detection         ~EUR 5 per vCPU
#   AKS Standard tier      uptime SLA                        ~EUR 65
#
# What is deliberately NOT disabled, because it is the point of the platform:
# workload identity federation, RBAC, default-deny network ACLs, Key Vault,
# ACR, Log Analytics, and the full GitOps path.
#
# Teardown is expected: `make destroy ENV=sandbox`.
# =============================================================================

locals {
  environment = "sandbox"

  common_tags = {
    platform    = var.name_prefix
    environment = local.environment
    managed-by  = "terraform"
    cost-centre = var.cost_centre
    owner       = var.owning_team
    data-class  = "none"
    # Marks the whole environment as disposable, for cost alerts and cleanup.
    lifecycle-policy = "delete-on-idle"
  }
}

data "azurerm_client_config" "current" {}

module "observability" {
  source = "../../modules/observability"

  name_prefix     = var.name_prefix
  environment     = local.environment
  location        = var.location
  subscription_id = var.subscription_id

  # A 0.5 GB/day cap is well inside the 5 GB/month Log Analytics free grant, so
  # ingestion stays free even if something starts logging in a loop.
  nonprod_daily_quota_gb = 0.5

  enable_managed_grafana = false
  enable_slo_alerts      = false

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

  # The two biggest fixed costs in the network module, and neither is needed to
  # demonstrate the platform. Egress falls back to load-balancer addresses,
  # which means no allowlistable static IP — the trade-off ADR-003 describes.
  enable_nat_gateway       = false
  enable_private_dns_zones = false

  availability_zones = []

  tags = local.common_tags
}

module "aks" {
  source = "../../modules/aks"

  name_prefix        = var.name_prefix
  environment        = local.environment
  location           = var.location
  kubernetes_version = var.kubernetes_version
  tenant_id          = var.tenant_id

  vnet_id          = module.network.vnet_id
  system_subnet_id = module.network.subnet_ids["system"]
  apps_subnet_id   = module.network.subnet_ids["apps"]

  # Public API server restricted to the operator's address. A private cluster
  # would need a bastion or self-hosted runner, which costs more than the
  # cluster it protects at this scale.
  private_cluster_enabled         = false
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges

  # ── The 4 vCPU budget, spent ──────────────────────────────────────────────
  # 2 x B2s (2 vCPU each). Burstable is the cheapest family that still meets
  # the AKS system-pool minimum of 2 vCPU / 4 GiB.
  system_pool_vm_size   = var.node_vm_size
  system_pool_min_count = 1
  system_pool_max_count = 2

  # No second pool: there is no quota for one. The system pool is therefore
  # left untainted by the module so workloads can schedule.
  enable_app_pool     = false
  enable_spot_pool    = false
  enable_windows_pool = false

  # B-series has no cache large enough for an ephemeral OS disk, and no zone
  # support on this subscription.
  system_pool_os_disk_type    = "Managed"
  system_pool_os_disk_size_gb = 32
  availability_zones          = []

  # Must agree with enable_nat_gateway = false above.
  outbound_type = "loadBalancer"

  # Bills per vCPU-hour.
  enable_defender = false

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

  # Lets the cluster pull from the registry this module creates.
  kubelet_identity_principal_id = module.aks.kubelet_identity_principal_id

  data_subnet_id       = module.network.subnet_ids["data"]
  apps_subnet_id       = module.network.subnet_ids["apps"]
  private_dns_zone_ids = module.network.private_dns_zone_ids

  # Basic ACR and standard Key Vault. Premium buys private link, geo-replication
  # and HSM keys — all of which this environment has deliberately turned off.
  acr_sku       = "Basic"
  key_vault_sku = "standard"

  # The vault is default-deny; without the operator's IP nothing outside the
  # cluster subnet could read or write a secret.
  allowed_ip_ranges = var.api_server_authorized_ip_ranges

  key_vault_csi_identity_object_id = module.aks.key_vault_secrets_provider_identity
  # A sandbox has no admin group, so the operator gets the assignment directly.
  platform_admin_group_object_ids = [data.azurerm_client_config.current.object_id]

  # Same workload set as every other environment, so the federation path being
  # exercised here is the one production uses.
  workload_identities = {
    payments-api = {
      namespace       = "payments"
      service_account = "payments-api"
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

  # Off by default: the reference app runs without a database, and SQL is the
  # single largest avoidable line item here. Set enable_sql = true in tfvars to
  # exercise the Entra-only authentication path.
  enable_sql               = var.enable_sql
  enable_private_endpoints = false

  nonprod_sku_name = "GP_S_Gen5_1"
  max_size_gb      = 32
  database_name    = var.database_name

  sql_admin_group_name      = var.sql_admin_group_name
  sql_admin_group_object_id = var.sql_admin_group_object_id != "" ? var.sql_admin_group_object_id : data.azurerm_client_config.current.object_id

  allowed_ip_ranges = var.api_server_authorized_ip_ranges

  workload_principal_ids = [
    module.platform_identity.workload_identity_principal_ids["payments-api"],
  ]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.common_tags
}

# ── Cluster access for the operator ──────────────────────────────────────────
# Azure RBAC is enabled and local accounts are disabled, so subscription Owner
# does not by itself grant Kubernetes data-plane access. Without this,
# `kubectl get pods` returns Forbidden on a cluster you own.
resource "azurerm_role_assignment" "operator_cluster_admin" {
  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "operator_cluster_user" {
  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── Cost guard rail ──────────────────────────────────────────────────────────
# The point of a sandbox on a real subscription is that it bills real money.
# This alerts before that becomes a surprise rather than after.
resource "azurerm_consumption_budget_subscription" "sandbox" {
  # A budget with no notification is inert — Azure requires at least one, and
  # so does the point of having it. Both conditions must hold.
  count = var.monthly_budget_eur > 0 && length(var.budget_alert_emails) > 0 ? 1 : 0

  name            = "budget-${var.name_prefix}-${local.environment}"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.monthly_budget_eur
  time_grain      = "Monthly"

  time_period {
    # Must start at the beginning of a month, and not in the past.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timeadd(timestamp(), "24h"))
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      threshold_type = notification.value == 100 ? "Forecasted" : "Actual"
      contact_emails = var.budget_alert_emails
    }
  }

  lifecycle {
    # start_date is derived from timestamp(), which changes on every plan.
    ignore_changes = [time_period]
  }
}
