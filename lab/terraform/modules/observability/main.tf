# =============================================================================
# Module: observability — metrics, logs, traces and on-call routing
# =============================================================================
# ADR-010: Three signal stores, one query surface.
#   metrics -> Azure Monitor Workspace (managed Prometheus) + Managed Grafana
#   logs    -> Log Analytics (platform/audit) and Elastic (application, high
#              cardinality, engineer-facing search in Kibana)
#   traces  -> Application Insights via the OTel collector, sampled
#
# The split is deliberate. Log Analytics is the compliance store: immutable,
# long retention, expensive per GB. Elastic is the debugging store: cheap
# per GB, short retention, full-text search. Sending everything to both would
# roughly double the observability bill for no diagnostic gain (see
# docs/DECISIONS.md for the cost model).
#
# ADR-011: Alerts route on symptoms (SLO burn rate), not causes (CPU%). A page
# means users are affected; everything else is a ticket.
# =============================================================================

locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "observability"
    environment = var.environment
  })

  is_prod = var.environment == "prod"
}

resource "azurerm_resource_group" "observability" {
  name     = "rg-${local.name_prefix}-observability"
  location = var.location
  tags     = local.common_tags
}

# ── Log Analytics: the compliance and platform-log store ─────────────────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.name_prefix}"
  location            = azurerm_resource_group.observability.location
  resource_group_name = azurerm_resource_group.observability.name
  sku                 = "PerGB2018"

  # Audit evidence must outlive an incident investigation window.
  retention_in_days = local.is_prod ? var.prod_log_retention_days : 30

  # A daily cap prevents a log-loop in one service from burning the month's
  # budget in an afternoon. Set to 0 (unlimited) in prod: dropping audit logs
  # to save money is not an acceptable trade.
  daily_quota_gb = local.is_prod ? -1 : var.nonprod_daily_quota_gb

  internet_ingestion_enabled = !local.is_prod
  internet_query_enabled     = true

  tags = local.common_tags
}

# ── Application Insights: distributed tracing ────────────────────────────────
resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name_prefix}"
  location            = azurerm_resource_group.observability.location
  resource_group_name = azurerm_resource_group.observability.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  # Head sampling at the collector keeps trace volume affordable; errors and
  # slow requests are always kept by the tail-sampling policy in the OTel
  # collector config (see lab/kubernetes/platform/otel-collector.yaml).
  sampling_percentage = local.is_prod ? var.prod_trace_sampling_percentage : 100

  retention_in_days            = 90
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  ip_masking_enabled           = true

  tags = local.common_tags
}

# ── Managed Prometheus + Grafana ─────────────────────────────────────────────
resource "azurerm_monitor_workspace" "prometheus" {
  name                = "amw-${local.name_prefix}"
  location            = azurerm_resource_group.observability.location
  resource_group_name = azurerm_resource_group.observability.name
  tags                = local.common_tags
}

resource "azurerm_dashboard_grafana" "main" {
  count = var.enable_managed_grafana ? 1 : 0

  name                              = "graf-${local.name_prefix}"
  resource_group_name               = azurerm_resource_group.observability.name
  location                          = azurerm_resource_group.observability.location
  grafana_major_version             = "11"
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = true
  public_network_access_enabled     = true
  zone_redundancy_enabled           = local.is_prod

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus.id
  }

  tags = local.common_tags
}

# Grafana queries Prometheus and Log Analytics with its own identity — no
# service account tokens, no API keys to rotate.
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  count = var.enable_managed_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.prometheus.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.main[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_subscription_reader" {
  count = var.enable_managed_grafana ? 1 : 0

  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.main[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_admins" {
  for_each = var.enable_managed_grafana ? toset(var.grafana_admin_group_object_ids) : toset([])

  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = each.value
}

# Scrape AKS into managed Prometheus.
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = "dce-prom-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location
  kind                = "Linux"
  tags                = local.common_tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = "dcr-prom-${local.name_prefix}"
  resource_group_name         = azurerm_resource_group.observability.name
  location                    = azurerm_resource_group.observability.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  tags                        = local.common_tags

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "aks_prometheus" {
  count = var.enable_aks_prometheus_scrape ? 1 : 0

  name                    = "dcra-prom-${local.name_prefix}"
  target_resource_id      = var.aks_cluster_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "Send AKS Prometheus metrics to the Azure Monitor workspace."
}

# ── On-call routing ──────────────────────────────────────────────────────────
# Two severities, two destinations. A page interrupts a human at 03:00, so the
# bar is "customers are currently affected"; everything else lands in Slack and
# is triaged in business hours.
resource "azurerm_monitor_action_group" "page" {
  name                = "ag-page-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  short_name          = substr("pg${var.environment}", 0, 12)
  tags                = local.common_tags

  dynamic "webhook_receiver" {
    for_each = var.pagerduty_webhook_url == "" ? [] : [1]
    content {
      name                    = "pagerduty"
      service_uri             = var.pagerduty_webhook_url
      use_common_alert_schema = true
    }
  }

  dynamic "email_receiver" {
    for_each = var.oncall_emails
    content {
      name                    = "oncall-${index(var.oncall_emails, email_receiver.value)}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_action_group" "ticket" {
  name                = "ag-ticket-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  short_name          = substr("tk${var.environment}", 0, 12)
  tags                = local.common_tags

  dynamic "webhook_receiver" {
    for_each = var.slack_webhook_url == "" ? [] : [1]
    content {
      name                    = "slack"
      service_uri             = var.slack_webhook_url
      use_common_alert_schema = true
    }
  }
}

# ── SLO alerts ───────────────────────────────────────────────────────────────
# Multi-window burn rate: a fast burn (2% of the monthly budget in an hour)
# pages immediately; a slow burn opens a ticket. This is what stops the
# "CPU > 80%" pages that wake people up for a healthy service.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "slo_fast_burn" {
  count = var.enable_slo_alerts ? 1 : 0

  name                = "alert-slo-fast-burn-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location
  description         = "Error budget burning 14.4x faster than sustainable — customers are affected now."
  severity            = 1
  enabled             = true

  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      requests
      | where timestamp > ago(1h)
      | summarize
          Total = count(),
          Failed = countif(success == false)
      | extend ErrorRate = todouble(Failed) / todouble(Total)
      | where Total > 100 and ErrorRate > ${var.slo_fast_burn_error_rate}
      | project ErrorRate
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.page.id]
  }

  tags = local.common_tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "slo_slow_burn" {
  count = var.enable_slo_alerts ? 1 : 0

  name                = "alert-slo-slow-burn-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location
  description         = "Error budget burning 6x faster than sustainable over 6h — degrading, not yet critical."
  severity            = 3
  enabled             = true

  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT30M"
  window_duration         = "PT6H"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      requests
      | where timestamp > ago(6h)
      | summarize
          Total = count(),
          Failed = countif(success == false)
      | extend ErrorRate = todouble(Failed) / todouble(Total)
      | where Total > 500 and ErrorRate > ${var.slo_slow_burn_error_rate}
      | project ErrorRate
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ticket.id]
  }

  tags = local.common_tags
}

# Latency is the second half of the SLO: a service returning 200s slowly is
# still failing its users.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "latency_p99" {
  count = var.enable_slo_alerts ? 1 : 0

  name                = "alert-latency-p99-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.observability.name
  location            = azurerm_resource_group.observability.location
  description         = "p99 request latency above the SLO target."
  severity            = 2
  enabled             = true

  scopes                  = [azurerm_application_insights.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      requests
      | where timestamp > ago(15m)
      | summarize P99 = percentile(duration, 99)
      | where P99 > ${var.slo_p99_latency_ms}
      | project P99
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 3
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ticket.id]
  }

  tags = local.common_tags
}

# ── Elastic / Datadog wiring ─────────────────────────────────────────────────
# Credentials for the shipping agents live in Key Vault and are mounted by the
# CSI driver; nothing is stored in a Kubernetes Secret or in this state file.
resource "azurerm_key_vault_secret" "elastic_api_key" {
  count = var.elastic_api_key == "" ? 0 : 1

  name         = "elastic-api-key"
  value        = var.elastic_api_key
  key_vault_id = var.key_vault_id
  content_type = "text/plain"

  tags = local.common_tags
}

resource "azurerm_key_vault_secret" "datadog_api_key" {
  count = var.datadog_api_key == "" ? 0 : 1

  name         = "datadog-api-key"
  value        = var.datadog_api_key
  key_vault_id = var.key_vault_id
  content_type = "text/plain"

  tags = local.common_tags
}

resource "azurerm_key_vault_secret" "appinsights_connection_string" {
  count = var.enable_key_vault_secrets ? 1 : 0

  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.main.connection_string
  key_vault_id = var.key_vault_id
  content_type = "text/plain"

  tags = local.common_tags
}
