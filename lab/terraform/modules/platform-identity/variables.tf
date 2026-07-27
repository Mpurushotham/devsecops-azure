variable "name_prefix" {
  description = "Short platform name used to build resource names."
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging or prod."
  type        = string

  validation {
    # "sandbox" is the quota-constrained shape used to exercise the modules
    # against a free-tier subscription; it behaves like dev but smaller.
    condition     = contains(["sandbox", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: sandbox, dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region for platform resources."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix that makes globally-unique names (ACR, Key Vault) collision-free."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.unique_suffix))
    error_message = "unique_suffix must be 3-8 lowercase alphanumeric characters."
  }
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL used as the federation issuer for workload identities."
  type        = string
}

variable "data_subnet_id" {
  description = "Subnet that hosts private endpoints."
  type        = string
}

variable "apps_subnet_id" {
  description = "Application subnet, allowed through the Key Vault network ACL in production."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Map of service key to private DNS zone ID, from the network module."
  type        = map(string)
}

variable "aks_cluster_id" {
  description = "AKS cluster resource ID, for the GitHub deploy identity role assignment."
  type        = string
  default     = ""
}

variable "key_vault_csi_identity_object_id" {
  description = "Object ID of the AKS Key Vault CSI driver identity."
  type        = string
  default     = ""
}

variable "platform_admin_group_object_ids" {
  description = "Entra ID groups granted Key Vault Administrator."
  type        = list(string)
  default     = []
}

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public CIDRs allowed through the Key Vault network ACL (office, VPN, CI
    egress). The ACL is default-deny in every environment, so this is the only
    way to reach the vault from outside the cluster subnet.
  EOT
  type        = list(string)
  default     = []
}

variable "workload_identities" {
  description = <<-EOT
    Workload identities to create, keyed by workload name. Each is federated to
    exactly one namespace/service-account pair, so an identity cannot be assumed
    from another namespace.
  EOT
  type = map(object({
    namespace                = string
    service_account          = string
    key_vault_secrets_access = optional(bool, true)
  }))
  default = {}
}

variable "github_repository" {
  description = "GitHub repo in owner/name form for OIDC federation. Empty disables the deploy identity."
  type        = string
  default     = ""
}

variable "acr_geo_replications" {
  description = "Additional regions to geo-replicate the production registry to."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for Key Vault and ACR diagnostics."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "acr_sku" {
  description = "Override the ACR SKU (Basic, Standard, Premium). Empty derives it from the environment."
  type        = string
  default     = ""
}

variable "key_vault_sku" {
  description = "Override the Key Vault SKU (standard, premium). Empty derives it from the environment."
  type        = string
  default     = ""
}

variable "enable_csi_driver_access" {
  description = "Grant the AKS Key Vault CSI identity read access to the vault."
  type        = bool
  default     = true
}

variable "enable_github_aks_reader" {
  description = "Grant the GitHub deploy identity Cluster User on the AKS cluster."
  type        = bool
  default     = true
}

variable "enable_diagnostics" {
  description = "Send Key Vault and ACR diagnostics to log_analytics_workspace_id."
  type        = bool
  default     = true
}

variable "rbac_propagation_seconds" {
  description = <<-EOT
    How long to wait after creating Key Vault role assignments before dependent
    resources write to the vault. Entra RBAC is eventually consistent and the
    data plane returns 403 until it converges. Zero disables the wait.
  EOT
  type        = number
  default     = 60
}

variable "kubelet_identity_principal_id" {
  description = <<-EOT
    Principal ID of the AKS kubelet identity, granted AcrPull on this registry.
    Empty skips the assignment. This is a plain input rather than a lookup so
    the dependency stays one-directional: AKS is created first, then this module
    grants the cluster access to the registry it creates.
  EOT
  type        = string
  default     = ""
}
