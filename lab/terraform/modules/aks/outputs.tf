output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.main.name
}

output "resource_group_name" {
  description = "Resource group holding the AKS cluster."
  value       = azurerm_resource_group.aks.name
}

output "node_resource_group" {
  description = "Auto-managed resource group holding the node VMSS and load balancers."
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL — the trust anchor for every workload identity federated credential."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_principal_id" {
  description = "Principal ID of the kubelet identity (holds AcrPull)."
  value       = azurerm_user_assigned_identity.kubelet.principal_id
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the control-plane identity."
  value       = azurerm_user_assigned_identity.cluster.principal_id
}

output "key_vault_secrets_provider_identity" {
  description = "Object ID of the Key Vault CSI driver identity — grant it read access on the vault."
  value       = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
}

output "host" {
  description = "Kubernetes API server endpoint."
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "kube_config_raw" {
  description = "Raw kubeconfig. Admin credentials are disabled, so this is the Entra-backed user config."
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}
