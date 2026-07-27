output "aks_cluster_name" {
  description = "AKS cluster name — used by `az aks get-credentials`."
  value       = module.aks.cluster_name
}

output "aks_resource_group" {
  description = "Resource group holding the AKS cluster."
  value       = module.aks.resource_group_name
}

output "acr_login_server" {
  description = "Registry to push images to."
  value       = module.platform_identity.acr_login_server
}

output "key_vault_name" {
  description = "Key Vault name, referenced by SecretProviderClass manifests."
  value       = module.platform_identity.key_vault_name
}

output "workload_identity_client_ids" {
  description = "Client IDs for each service account's azure.workload.identity/client-id annotation."
  value       = module.platform_identity.workload_identity_client_ids
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer — the trust anchor for workload identity."
  value       = module.aks.oidc_issuer_url
}

output "storage_account_name" {
  description = "Platform storage account."
  value       = module.data.storage_account_name
}

output "sql_server_fqdn" {
  description = "SQL server FQDN. Empty when enable_sql is false."
  value       = module.data.sql_server_fqdn
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = module.observability.log_analytics_workspace_id
}

output "next_steps" {
  description = "What to run after a successful apply."
  value       = <<-EOT

    Cluster credentials:
      az aks get-credentials -g ${module.aks.resource_group_name} -n ${module.aks.cluster_name} --overwrite-existing
      kubectl get nodes

    Push an image:
      az acr login -n ${module.platform_identity.acr_login_server}
      docker build -t ${module.platform_identity.acr_login_server}/payments-api:v1 lab/apps/payments-api
      docker push ${module.platform_identity.acr_login_server}/payments-api:v1

    Tear down when finished — this environment bills by the hour:
      make destroy ENV=sandbox
  EOT
}
