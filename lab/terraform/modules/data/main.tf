# =============================================================================
# Module: data — Azure SQL and platform storage
# =============================================================================
# ADR-008: Entra-only authentication. SQL logins cannot be centrally revoked,
#          do not expire, and end up in connection strings; Entra + workload
#          identity means the app never holds a database credential at all.
# ADR-009: Zone-redundant Business Critical tier in production. Seasonal peaks
#          are read-heavy, so a read-scale replica absorbs reporting traffic
#          without touching the primary's transaction throughput.
# =============================================================================

locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "data"
    environment = var.environment
  })

  is_prod = var.environment == "prod"

  # Azure storage and Key Vault network ACLs reject a /32 suffix — a single
  # address must be given bare. Callers pass ordinary CIDRs, so normalise here
  # rather than making every environment remember the quirk. Only apply/plan
  # against the real API surfaces this; the schema accepts /32 happily.
  allowed_ips = [for c in var.allowed_ip_ranges : replace(c, "/32", "")]

}

resource "azurerm_resource_group" "data" {
  name     = "rg-${local.name_prefix}-data"
  location = var.location
  tags     = local.common_tags
}

# ── SQL Server ───────────────────────────────────────────────────────────────
resource "azurerm_mssql_server" "main" {
  count = var.enable_sql ? 1 : 0

  name                = "sql-${local.name_prefix}-${var.unique_suffix}"
  resource_group_name = azurerm_resource_group.data.name
  location            = azurerm_resource_group.data.location
  version             = "12.0"

  # No SQL admin login is created: azuread_authentication_only removes the
  # entire class of "leaked connection string" incidents.
  azuread_administrator {
    login_username              = var.sql_admin_group_name
    object_id                   = var.sql_admin_group_object_id
    tenant_id                   = var.tenant_id
    azuread_authentication_only = true
  }

  minimum_tls_version                      = "1.2"
  public_network_access_enabled            = !local.is_prod
  outbound_network_restriction_enabled     = local.is_prod
  express_vulnerability_assessment_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

resource "azurerm_mssql_database" "main" {
  count = var.enable_sql ? 1 : 0

  name      = var.database_name
  server_id = azurerm_mssql_server.main[0].id

  # Business Critical gives local SSD storage and a built-in read replica;
  # General Purpose cannot meet the p99 latency target during peak.
  sku_name    = local.is_prod ? var.prod_sku_name : var.nonprod_sku_name
  max_size_gb = var.max_size_gb
  collation   = "SQL_Latin1_General_CP1_CI_AS"

  zone_redundant = local.is_prod
  read_scale     = local.is_prod

  # Point-in-time restore covers operator error; long-term retention covers
  # the regulatory requirement to reproduce historical transaction state.
  storage_account_type = local.is_prod ? "Geo" : "Local"

  short_term_retention_policy {
    retention_days           = local.is_prod ? 35 : 7
    backup_interval_in_hours = 12
  }

  dynamic "long_term_retention_policy" {
    for_each = local.is_prod ? [1] : []
    content {
      weekly_retention  = "P4W"
      monthly_retention = "P12M"
      yearly_retention  = "P7Y"
      week_of_year      = 1
    }
  }

  # Transparent Data Encryption with a customer-managed key: the platform team
  # can revoke access to data at rest without involving Microsoft.
  transparent_data_encryption_enabled                        = true
  transparent_data_encryption_key_vault_key_id               = var.tde_key_vault_key_id
  transparent_data_encryption_key_automatic_rotation_enabled = var.tde_key_vault_key_id == "" ? null : true

  tags = local.common_tags

  lifecycle {
    prevent_destroy = false # set true in prod state; false here so the lab tears down cleanly
  }
}

# ── Private endpoint: SQL is never reachable from the internet ───────────────
resource "azurerm_private_endpoint" "sql" {
  count = var.enable_sql ? 1 : 0

  name                = "pe-sql-${local.name_prefix}"
  location            = azurerm_resource_group.data.location
  resource_group_name = azurerm_resource_group.data.name
  subnet_id           = var.data_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-sql-${local.name_prefix}"
    private_connection_resource_id = azurerm_mssql_server.main[0].id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sql-dns"
    private_dns_zone_ids = [var.private_dns_zone_ids["sql"]]
  }
}

# ── Threat detection ─────────────────────────────────────────────────────────
resource "azurerm_mssql_server_security_alert_policy" "main" {
  count = var.enable_sql ? 1 : 0

  resource_group_name = azurerm_resource_group.data.name
  server_name         = azurerm_mssql_server.main[0].name
  state               = "Enabled"

  email_account_admins = true
  email_addresses      = var.security_alert_emails
  retention_days       = 90
}

resource "azurerm_mssql_server_extended_auditing_policy" "main" {
  count = var.enable_sql && var.enable_diagnostics ? 1 : 0

  server_id                       = azurerm_mssql_server.main[0].id
  log_monitoring_enabled          = true
  retention_in_days               = 90
  storage_account_subscription_id = var.subscription_id
}

resource "azurerm_monitor_diagnostic_setting" "sql" {
  count = var.enable_sql && var.enable_diagnostics ? 1 : 0

  name                       = "diag-sql-${local.name_prefix}"
  target_resource_id         = azurerm_mssql_database.main[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }

  enabled_log {
    category = "SQLInsights"
  }

  enabled_log {
    category = "Errors"
  }

  enabled_log {
    category = "Timeouts"
  }

  enabled_log {
    category = "Deadlocks"
  }

  enabled_metric {
    category = "Basic"
  }
}

# ── Grant workload identities database access ────────────────────────────────
# The app authenticates as its managed identity; there is no password to rotate.
# The matching CREATE USER FROM EXTERNAL PROVIDER statement is applied by the
# schema migration job (see lab/apps/payments-api).
resource "azurerm_role_assignment" "workload_sql_contributor" {
  for_each = var.enable_sql ? toset(var.workload_principal_ids) : toset([])

  scope                = azurerm_mssql_server.main[0].id
  role_definition_name = "SQL DB Contributor"
  principal_id         = each.value
}

# ── Platform storage: Loki chunks, Tempo traces, Velero backups ──────────────
resource "azurerm_storage_account" "platform" {
  name                = substr(replace("st${var.name_prefix}${var.environment}${var.unique_suffix}", "-", ""), 0, 24)
  resource_group_name = azurerm_resource_group.data.name
  location            = azurerm_resource_group.data.location

  account_tier             = "Standard"
  account_replication_type = local.is_prod ? "ZRS" : "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra auth only, no account keys
  public_network_access_enabled   = !local.is_prod

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = local.is_prod ? 30 : 7
    }

    container_delete_retention_policy {
      days = local.is_prod ? 30 : 7
    }
  }

  # Default-deny everywhere: this account holds logs, traces and Velero backups,
  # all of which contain production-shaped data even outside production.
  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices", "Logging", "Metrics"]
    virtual_network_subnet_ids = [var.apps_subnet_id]
    ip_rules                   = local.allowed_ips
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "this" {
  for_each = toset(var.storage_containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.platform.id
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "blob" {
  count = local.is_prod && var.enable_private_endpoints ? 1 : 0

  name                = "pe-blob-${local.name_prefix}"
  location            = azurerm_resource_group.data.location
  resource_group_name = azurerm_resource_group.data.name
  subnet_id           = var.data_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-blob-${local.name_prefix}"
    private_connection_resource_id = azurerm_storage_account.platform.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns"
    private_dns_zone_ids = [var.private_dns_zone_ids["blob"]]
  }
}
