output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.id
}

output "kube_config" {
  description = "Raw kubeconfig for the AKS cluster. Treat as sensitive – contains cluster credentials."
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "cluster_fqdn" {
  description = "Private FQDN of the AKS cluster API server."
  value       = azurerm_kubernetes_cluster.main.private_fqdn
}

output "cluster_portal_fqdn" {
  description = "Public portal FQDN (present even for private clusters; resolves only from within the vnet)."
  value       = azurerm_kubernetes_cluster.main.portal_fqdn
}

output "acr_login_server" {
  description = "Login server hostname of the Azure Container Registry."
  value       = azurerm_container_registry.main.login_server
}

output "acr_id" {
  description = "Resource ID of the Azure Container Registry."
  value       = azurerm_container_registry.main.id
}

output "key_vault_uri" {
  description = "Vault URI of the Azure Key Vault used for etcd encryption."
  value       = azurerm_key_vault.main.vault_uri
}

output "key_vault_id" {
  description = "Resource ID of the Azure Key Vault."
  value       = azurerm_key_vault.main.id
}

output "etcd_key_id" {
  description = "Versioned key identifier of the customer-managed etcd encryption key."
  value       = azurerm_key_vault_key.etcd.id
  sensitive   = true
}

output "node_resource_group" {
  description = "Name of the auto-generated resource group that holds AKS node infrastructure."
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster, required when configuring workload identity federation."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet managed identity. Used to grant additional Azure RBAC roles to nodes."
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "cluster_managed_identity_principal_id" {
  description = "Principal ID of the user-assigned managed identity attached to the AKS control plane."
  value       = azurerm_user_assigned_identity.aks.principal_id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace used for Container Insights and diagnostics."
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace GUID (customer ID) of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}
