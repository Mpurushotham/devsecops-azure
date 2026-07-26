output "aks_cluster_name" {
  description = "AKS cluster name — used by `az aks get-credentials`."
  value       = module.aks.cluster_name
}

output "aks_resource_group" {
  description = "Resource group holding the AKS cluster."
  value       = module.aks.resource_group_name
}

output "acr_login_server" {
  description = "Registry to push images to. Also the allowed registry in the Kyverno policy."
  value       = module.platform_identity.acr_login_server
}

output "key_vault_name" {
  description = "Key Vault name, referenced by SecretProviderClass manifests."
  value       = module.platform_identity.key_vault_name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = module.platform_identity.key_vault_uri
}

output "workload_identity_client_ids" {
  description = "Client IDs to place in each service account's azure.workload.identity/client-id annotation."
  value       = module.platform_identity.workload_identity_client_ids
}

output "github_deploy_identity_client_id" {
  description = "Client ID for the azure/login OIDC step in GitHub Actions."
  value       = module.platform_identity.github_deploy_identity_client_id
}

output "sql_server_fqdn" {
  description = "SQL server FQDN (resolves privately inside the VNet)."
  value       = module.data.sql_server_fqdn
}

output "sql_connection_string_template" {
  description = "Passwordless connection string for the application."
  value       = module.data.connection_string_template
}

output "nat_egress_ip" {
  description = "Static egress IP to give payment processors for allowlisting."
  value       = module.network.nat_egress_ip
}

output "grafana_endpoint" {
  description = "Managed Grafana URL."
  value       = module.observability.grafana_endpoint
}

output "application_insights_connection_string" {
  description = "App Insights connection string for the OTel collector."
  value       = module.observability.application_insights_connection_string
  sensitive   = true
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = module.observability.log_analytics_workspace_id
}
