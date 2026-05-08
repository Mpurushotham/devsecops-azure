variable "resource_group_name" {
  description = "Name of the Azure resource group where AKS and supporting resources are deployed."
  type        = string
  default     = "aks-multizone-rg"
}

variable "location" {
  description = "Azure region for all resources. Must support Availability Zones."
  type        = string
  default     = "eastus2"
}

variable "cluster_name" {
  description = "Name of the AKS cluster."
  type        = string
  default     = "aks-multizone-prod"
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy. Pin to a supported minor version."
  type        = string
  default     = "1.28"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS cluster API server FQDN."
  type        = string
  default     = "aks-multizone"
}

# System node pool (Zone A)
variable "system_node_pool_name" {
  description = "Name of the system node pool. Must start with a lowercase letter and be ≤11 chars."
  type        = string
  default     = "systempool"
}

variable "system_node_pool_vm_size" {
  description = "VM SKU for the system node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "system_node_pool_min_count" {
  description = "Minimum node count for the system node pool auto-scaler."
  type        = number
  default     = 1
}

variable "system_node_pool_max_count" {
  description = "Maximum node count for the system node pool auto-scaler."
  type        = number
  default     = 3
}

# App node pool – Zone B
variable "app_pool_b_name" {
  description = "Name of the application node pool in Zone B."
  type        = string
  default     = "apppoolb"
}

variable "app_node_pool_vm_size" {
  description = "VM SKU for the application node pools (Zones B and C)."
  type        = string
  default     = "Standard_D8s_v5"
}

variable "app_node_pool_min_count" {
  description = "Minimum node count for each application node pool."
  type        = number
  default     = 2
}

variable "app_node_pool_max_count" {
  description = "Maximum node count for each application node pool."
  type        = number
  default     = 10
}

# App node pool – Zone C
variable "app_pool_c_name" {
  description = "Name of the application node pool in Zone C."
  type        = string
  default     = "apppoolc"
}

# Networking
variable "vnet_subnet_id" {
  description = "Resource ID of the subnet where AKS nodes are placed (Azure CNI)."
  type        = string
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes service addresses. Must not overlap with vnet_subnet_id."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "IP address within service_cidr assigned to the Kubernetes DNS service."
  type        = string
  default     = "10.0.0.10"
}

variable "authorized_ip_ranges" {
  description = "List of CIDR blocks permitted to reach the AKS API server."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

# AAD / RBAC
variable "aad_admin_group_object_ids" {
  description = "List of Azure AD group object IDs granted cluster-admin via AAD RBAC."
  type        = list(string)
  default     = []
}

variable "tenant_id" {
  description = "Azure AD tenant ID used for AAD integration and Key Vault access policies."
  type        = string
}

# Key Vault
variable "key_vault_name" {
  description = "Globally unique name for the Azure Key Vault holding the etcd encryption key."
  type        = string
  default     = "aks-kv-prod"
}

variable "key_vault_sku" {
  description = "Key Vault SKU. Use 'premium' for HSM-backed keys."
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku)
    error_message = "key_vault_sku must be 'standard' or 'premium'."
  }
}

# ACR
variable "acr_name" {
  description = "Globally unique name for the Azure Container Registry (alphanumeric, 5-50 chars)."
  type        = string
  default     = "aksdevsecopsprod"
}

variable "acr_sku" {
  description = "ACR SKU. Premium is required for geo-replication and private endpoints."
  type        = string
  default     = "Premium"
}

# Log Analytics
variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace used for AKS diagnostics and Container Insights."
  type        = string
  default     = "aks-law-prod"
}

variable "log_analytics_retention_days" {
  description = "Number of days to retain data in the Log Analytics workspace."
  type        = number
  default     = 90
}

# AGIC
variable "agic_subnet_id" {
  description = "Resource ID of the subnet dedicated to the Application Gateway used by AGIC."
  type        = string
}

variable "tags" {
  description = "Map of tags applied to all resources."
  type        = map(string)
  default = {
    environment = "production"
    team        = "platform"
    managed_by  = "terraform"
  }
}
