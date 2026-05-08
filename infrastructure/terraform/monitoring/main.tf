terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Resource group for monitoring resources."
  type        = string
  default     = "aks-monitoring-rg"
}

variable "location" {
  description = "Azure region for all monitoring resources."
  type        = string
  default     = "eastus2"
}

variable "log_analytics_workspace_name" {
  description = "Name of the central Log Analytics workspace."
  type        = string
  default     = "aks-law-monitoring"
}

variable "log_analytics_retention_days" {
  description = "Data retention in days for the Log Analytics workspace (30–730)."
  type        = number
  default     = 90
}

variable "azure_monitor_workspace_name" {
  description = "Name of the Azure Monitor workspace (managed Prometheus)."
  type        = string
  default     = "aks-amw-prod"
}

variable "grafana_workspace_name" {
  description = "Name of the Azure Managed Grafana workspace."
  type        = string
  default     = "aks-grafana-prod"
}

variable "aks_cluster_id" {
  description = "Resource ID of the AKS cluster to monitor."
  type        = string
}

variable "aks_node_resource_group" {
  description = "Node resource group of the AKS cluster (for VM-level DCR association)."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address for critical monitoring alerts."
  type        = string
  default     = "platform@example.com"
}

variable "pagerduty_webhook_url" {
  description = "PagerDuty Events API v2 integration URL for P1 alerts."
  type        = string
  default     = "https://events.pagerduty.com/integration/REPLACE_ME/enqueue"
}

variable "tags" {
  description = "Tags applied to all monitoring resources."
  type        = map(string)
  default = {
    environment = "production"
    team        = "platform"
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "monitoring" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace – 90-day retention, central SIEM sink
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = var.log_analytics_workspace_name
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  # Enable daily cap to guard against runaway ingestion costs
  daily_quota_gb = 50

  tags = var.tags
}

# ContainerInsights solution linked to the workspace
resource "azurerm_log_analytics_solution" "container_insights" {
  solution_name         = "ContainerInsights"
  resource_group_name   = azurerm_resource_group.monitoring.name
  location              = azurerm_resource_group.monitoring.location
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}

# ---------------------------------------------------------------------------
# Azure Monitor Workspace – stores managed Prometheus metrics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_workspace" "main" {
  name                = var.azure_monitor_workspace_name
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Azure Managed Grafana – connected to Prometheus and Log Analytics
# ---------------------------------------------------------------------------
resource "azurerm_dashboard_grafana" "main" {
  name                              = var.grafana_workspace_name
  resource_group_name               = azurerm_resource_group.monitoring.name
  location                          = azurerm_resource_group.monitoring.location
  sku                               = "Standard"
  grafana_major_version             = 10
  public_network_access_enabled     = false
  zone_redundancy_enabled           = true
  api_key_enabled                   = false

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.main.id
  }

  tags = var.tags
}

# Allow Grafana's managed identity to read Prometheus metrics
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = azurerm_monitor_workspace.main.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

# Allow Grafana to query Log Analytics
resource "azurerm_role_assignment" "grafana_law_reader" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Data Collection Rule – container logs and metrics via Azure Monitor Agent
# ---------------------------------------------------------------------------
resource "azurerm_monitor_data_collection_rule" "aks_container_logs" {
  name                = "aks-container-logs-dcr"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  description         = "Collects stdout/stderr container logs and Perf counters from AKS nodes."
  kind                = "Linux"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
      name                  = "law-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerLog", "Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]
    destinations = ["law-destination"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      streams        = ["Microsoft-ContainerLog", "Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }

  tags = var.tags
}

# Associate the DCR with the AKS cluster
resource "azurerm_monitor_data_collection_rule_association" "aks_cluster" {
  name                    = "aks-cluster-dcra"
  target_resource_id      = var.aks_cluster_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.aks_container_logs.id
  description             = "Associates the container log DCR with the AKS cluster resource."
}

# ---------------------------------------------------------------------------
# Data Collection Rule – Prometheus metrics (managed scraping)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_data_collection_rule" "aks_prometheus" {
  name                = "aks-prometheus-dcr"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  description         = "Managed Prometheus scraping for AKS – sends metrics to Azure Monitor workspace."
  kind                = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.main.id
      name               = "amw-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["amw-destination"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_data_collection_rule_association" "aks_prometheus" {
  name                    = "aks-prometheus-dcra"
  target_resource_id      = var.aks_cluster_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.aks_prometheus.id
  description             = "Associates the Prometheus DCR with the AKS cluster."
}

# ---------------------------------------------------------------------------
# Action Group – email + PagerDuty for critical alerts
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "critical" {
  name                = "aks-critical-action-group"
  resource_group_name = azurerm_resource_group.monitoring.name
  short_name          = "akscrit"

  email_receiver {
    name                    = "PlatformTeam"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  webhook_receiver {
    name                    = "PagerDuty"
    service_uri             = var.pagerduty_webhook_url
    use_common_alert_schema = true
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Alert Rule – Critical CVE detected by Defender for Containers
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "critical_cve" {
  name                 = "aks-critical-cve-detected"
  resource_group_name  = azurerm_resource_group.monitoring.name
  location             = azurerm_resource_group.monitoring.location
  display_name         = "Critical CVE Detected in AKS Container Image"
  description          = "Alert fires when Defender for Containers reports a Critical-severity vulnerability in a running container image."
  severity             = 0  # Critical
  enabled              = true
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      SecurityAlert
      | where AlertType has "Containers"
        and Severity == "High"
        and Status != "Dismissed"
      | project TimeGenerated, AlertName, Severity, Description, RemediationSteps, Entities
    QUERY
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Alert Rule – AKS Node CPU > 85% sustained for 10 minutes
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "node_cpu_high" {
  name                 = "aks-node-cpu-high"
  resource_group_name  = azurerm_resource_group.monitoring.name
  location             = azurerm_resource_group.monitoring.location
  display_name         = "AKS Node CPU Utilisation > 85%"
  description          = "Fires when any AKS node reports average CPU usage above 85% for 10 minutes."
  severity             = 1  # Error
  enabled              = true
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      Perf
      | where ObjectName == "Processor" and CounterName == "% Processor Time"
      | summarize AvgCPU = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
      | where AvgCPU > 85
    QUERY
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Alert Rule – Kubernetes API server error rate spike
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "apiserver_errors" {
  name                 = "aks-apiserver-error-rate"
  resource_group_name  = azurerm_resource_group.monitoring.name
  location             = azurerm_resource_group.monitoring.location
  display_name         = "AKS API Server 5xx Error Rate Elevated"
  description          = "Fires when the kube-apiserver logs more than 10 server errors in a 5-minute window."
  severity             = 1
  enabled              = true
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      AzureDiagnostics
      | where Category == "kube-apiserver"
        and log_s has_any ("500", "503")
      | summarize ErrorCount = count() by bin(TimeGenerated, 5m)
      | where ErrorCount > 10
    QUERY
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Alert Rule – Pod restart storm (OOMKilled / CrashLoopBackOff)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pod_restarts" {
  name                 = "aks-pod-restart-storm"
  resource_group_name  = azurerm_resource_group.monitoring.name
  location             = azurerm_resource_group.monitoring.location
  display_name         = "AKS Pod Restart Storm"
  description          = "Fires when more than 5 pods have restarted more than 3 times within 10 minutes."
  severity             = 1
  enabled              = true
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [azurerm_log_analytics_workspace.main.id]

  criteria {
    query = <<-QUERY
      KubePodInventory
      | where ContainerRestartCount > 3
      | summarize AffectedPods = dcount(Name) by bin(TimeGenerated, 5m)
      | where AffectedPods > 5
    QUERY
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Security Compliance Dashboard (Azure Workbook)
# ---------------------------------------------------------------------------
resource "azurerm_application_insights_workbook" "security_compliance" {
  name                = "aks-security-compliance-workbook"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  display_name        = "AKS Security Compliance Dashboard"
  description         = "Consolidated view of CVE findings, policy compliance, audit events, and runtime security alerts."

  source_id = azurerm_log_analytics_workspace.main.id

  serialized_data = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        content = {
          json = "## AKS Security Compliance\nThis workbook provides a real-time view of the security posture of AKS multi-zone cluster.\n\n**Sections**: CVE findings | Defender alerts | Policy compliance | Audit events"
        }
        name = "header"
      },
      {
        type  = 3
        name  = "cve-query"
        content = {
          version = "KqlItem/1.0"
          query   = "SecurityAlert | where AlertType has 'Containers' | summarize count() by Severity, bin(TimeGenerated, 1d) | render barchart"
          queryType = 0
          resourceType = "microsoft.operationalinsights/workspaces"
          timeContext = { durationMs = 604800000 }
          visualization = "barchart"
          title = "Defender for Containers Alerts (last 7d)"
        }
      },
      {
        type  = 3
        name  = "policy-compliance"
        content = {
          version = "KqlItem/1.0"
          query   = "PolicyStates | where PolicyDefinitionCategory has 'Kubernetes' | summarize count() by ComplianceState | render piechart"
          queryType = 0
          resourceType = "microsoft.operationalinsights/workspaces"
          timeContext = { durationMs = 86400000 }
          visualization = "piechart"
          title = "Kubernetes Policy Compliance"
        }
      },
      {
        type  = 3
        name  = "audit-events"
        content = {
          version = "KqlItem/1.0"
          query   = "AzureDiagnostics | where Category == 'kube-audit' | summarize count() by verb_s, objectRef_resource_s | top 20 by count_"
          queryType = 0
          resourceType = "microsoft.operationalinsights/workspaces"
          timeContext = { durationMs = 86400000 }
          visualization = "table"
          title = "Top Kubernetes Audit Events (last 24h)"
        }
      }
    ]
    fallbackResourceIds = [azurerm_log_analytics_workspace.main.id]
  })

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "log_analytics_workspace_id" {
  description = "Resource ID of the central Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace GUID (customer ID) used in agent configurations."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "azure_monitor_workspace_id" {
  description = "Resource ID of the Azure Monitor workspace (managed Prometheus)."
  value       = azurerm_monitor_workspace.main.id
}

output "grafana_endpoint" {
  description = "HTTPS endpoint of the Azure Managed Grafana workspace."
  value       = azurerm_dashboard_grafana.main.endpoint
}

output "grafana_id" {
  description = "Resource ID of the Azure Managed Grafana workspace."
  value       = azurerm_dashboard_grafana.main.id
}

output "action_group_id" {
  description = "Resource ID of the critical alert action group."
  value       = azurerm_monitor_action_group.critical.id
}
