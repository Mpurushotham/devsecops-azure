output "resource_group_name" {
  description = "Resource group holding platform identity resources."
  value       = azurerm_resource_group.platform.name
}

output "acr_id" {
  description = "Resource ID of the container registry."
  value       = azurerm_container_registry.main.id
}

output "acr_login_server" {
  description = "ACR login server, used as the image prefix in Helm values and Kyverno registry allowlists."
  value       = azurerm_container_registry.main.login_server
}

output "key_vault_id" {
  description = <<-EOT
    Resource ID of the Key Vault. Gated behind the RBAC propagation wait, so any
    module that writes a secret using this id is ordered after the role
    assignments have had time to converge.
  EOT
  value       = azurerm_key_vault.main.id
  depends_on  = [time_sleep.kv_rbac_propagation]
}

output "key_vault_uri" {
  description = "Key Vault URI, referenced by SecretProviderClass manifests."
  value       = azurerm_key_vault.main.vault_uri
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.main.name
}

output "workload_identity_client_ids" {
  description = "Map of workload name to client ID — goes into the service account's azure.workload.identity/client-id annotation."
  value       = { for k, id in azurerm_user_assigned_identity.workload : k => id.client_id }
}

output "workload_identity_principal_ids" {
  description = "Map of workload name to principal ID, for additional role assignments."
  value       = { for k, id in azurerm_user_assigned_identity.workload : k => id.principal_id }
}

output "github_deploy_identity_client_id" {
  description = "Client ID for the GitHub Actions OIDC login (azure/login client-id input)."
  value       = try(azurerm_user_assigned_identity.github_deploy[0].client_id, "")
}
