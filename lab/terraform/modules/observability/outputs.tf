output "resource_group_name" {
  description = "Resource group holding observability resources."
  value       = azurerm_resource_group.observability.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID, consumed by AKS, Key Vault and SQL diagnostics."
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_guid" {
  description = "Log Analytics workspace GUID, used by traffic analytics and agent config."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "application_insights_id" {
  description = "Application Insights resource ID."
  value       = azurerm_application_insights.main.id
}

output "application_insights_connection_string" {
  description = "Connection string for the OTel exporter. Also mirrored into Key Vault."
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "prometheus_workspace_id" {
  description = "Azure Monitor (managed Prometheus) workspace resource ID."
  value       = azurerm_monitor_workspace.prometheus.id
}

output "prometheus_query_endpoint" {
  description = "PromQL query endpoint, used as the Grafana data source URL."
  value       = azurerm_monitor_workspace.prometheus.query_endpoint
}

output "grafana_endpoint" {
  description = "Managed Grafana URL."
  value       = try(azurerm_dashboard_grafana.main[0].endpoint, "")
}

output "action_group_page_id" {
  description = "Action group that pages on-call — wire customer-impacting alerts here only."
  value       = azurerm_monitor_action_group.page.id
}

output "action_group_ticket_id" {
  description = "Action group that opens a ticket for non-urgent degradation."
  value       = azurerm_monitor_action_group.ticket.id
}
