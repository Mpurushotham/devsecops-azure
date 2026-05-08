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
# Variables (inline for single-file module; extract to variables.tf as needed)
# ---------------------------------------------------------------------------
variable "resource_group_name" { default = "aks-security-rg" }
variable "location"            { default = "eastus2" }
variable "tenant_id"           {}
variable "log_analytics_workspace_id" {}
variable "log_analytics_workspace_location" { default = "eastus2" }
variable "event_hub_namespace_id"  { default = "" }
variable "event_hub_name"          { default = "" }
variable "event_hub_authorization_rule_id" { default = "" }
variable "alert_email"         { default = "secops@example.com" }
variable "pagerduty_webhook_url" { default = "https://events.pagerduty.com/integration/REPLACE_ME/enqueue" }
variable "aks_cluster_id"      {}
variable "subscription_id"     {}

variable "tags" {
  default = {
    environment = "production"
    managed_by  = "terraform"
    team        = "security"
  }
}

resource "azurerm_resource_group" "security" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Microsoft Defender for Cloud – Security Center pricing tiers
# ---------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "ContainerRegistry"
}

resource "azurerm_security_center_subscription_pricing" "aks" {
  tier          = "Standard"
  resource_type = "KubernetesService"
}

resource "azurerm_security_center_subscription_pricing" "arm" {
  tier          = "Standard"
  resource_type = "Arm"
}

resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
  subplan       = "P2"
}

resource "azurerm_security_center_subscription_pricing" "dns" {
  tier          = "Standard"
  resource_type = "Dns"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  tier          = "Standard"
  resource_type = "StorageAccounts"
}

# Route Defender for Cloud alerts to Log Analytics
resource "azurerm_security_center_workspace" "main" {
  scope        = "/subscriptions/${var.subscription_id}"
  workspace_id = var.log_analytics_workspace_id
}

# ---------------------------------------------------------------------------
# Microsoft Sentinel – connect to existing Log Analytics workspace
# ---------------------------------------------------------------------------
resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  workspace_id                 = var.log_analytics_workspace_id
  customer_managed_key_enabled = false
}

# Azure Activity connector (audit logs into Sentinel)
resource "azurerm_sentinel_data_connector_azure_active_directory" "main" {
  name                       = "aad-connector"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  depends_on                 = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

resource "azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection" "main" {
  name                       = "mdatp-connector"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  depends_on                 = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# ---------------------------------------------------------------------------
# Azure Policy – CIS Kubernetes Benchmark initiative on AKS
# ---------------------------------------------------------------------------
resource "azurerm_subscription_policy_assignment" "cis_aks" {
  name                 = "cis-aks-benchmark"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
  display_name         = "CIS Microsoft Azure Foundations Benchmark – AKS"
  description          = "Enforces CIS Level 1 and Level 2 controls for AKS clusters."
  enforce              = true

  identity {
    type = "SystemAssigned"
  }

  location = var.location
}

resource "azurerm_subscription_policy_assignment" "aks_pod_security" {
  name                 = "aks-pod-security-restricted"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
  display_name         = "Kubernetes cluster pod security restricted standards"
  enforce              = true

  identity {
    type = "SystemAssigned"
  }

  location = var.location
}

# ---------------------------------------------------------------------------
# Key Vault (security plane) with private endpoint
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "security" {
  name                            = "aks-sec-kv-${substr(var.subscription_id, 0, 8)}"
  resource_group_name             = azurerm_resource_group.security.name
  location                        = azurerm_resource_group.security.location
  tenant_id                       = var.tenant_id
  sku_name                        = "premium"
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

resource "azurerm_role_assignment" "terraform_sec_kv_admin" {
  scope                = azurerm_key_vault.security.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Diagnostic Settings – AKS control plane logs to Log Analytics and Event Hub
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "aks_security" {
  name                           = "aks-security-diag"
  target_resource_id             = var.aks_cluster_id
  log_analytics_workspace_id     = var.log_analytics_workspace_id

  # Event Hub routing (SIEM ingestion) – conditionally set when the rule ID is provided
  eventhub_authorization_rule_id = var.event_hub_authorization_rule_id != "" ? var.event_hub_authorization_rule_id : null
  eventhub_name                  = var.event_hub_name != "" ? var.event_hub_name : null

  enabled_log { category = "kube-audit" }
  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "guard" }
  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "cluster-autoscaler" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ---------------------------------------------------------------------------
# Azure Monitor Action Group (email + PagerDuty webhook)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "secops" {
  name                = "secops-action-group"
  resource_group_name = azurerm_resource_group.security.name
  short_name          = "secops"

  email_receiver {
    name                    = "SecurityOps"
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
# Defender for DevOps connector (GitHub / Azure DevOps)
# ---------------------------------------------------------------------------
resource "azurerm_security_center_setting" "mcsb" {
  setting_name = "MCAS"
  enabled      = true
}

resource "azurerm_security_center_setting" "wdatp" {
  setting_name = "WDATP"
  enabled      = true
}

# ---------------------------------------------------------------------------
# Alert rule: Defender for Containers – critical vulnerability detected
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "critical_cve_alert" {
  name                = "critical-cve-detected"
  resource_group_name = azurerm_resource_group.security.name
  location            = azurerm_resource_group.security.location
  display_name        = "Critical CVE detected in container image"
  description         = "Fires when Defender for Containers surfaces a Critical severity vulnerability assessment finding."
  severity            = 0
  enabled             = true
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  scopes               = [var.log_analytics_workspace_id]

  criteria {
    query = <<-QUERY
      SecurityAlert
      | where AlertType has "Containers"
        and Severity == "High"
        and Status != "Dismissed"
      | project TimeGenerated, AlertName, Severity, Description, RemediationSteps
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
    action_groups = [azurerm_monitor_action_group.secops.id]
  }

  tags = var.tags
}
