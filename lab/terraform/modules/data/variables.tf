variable "name_prefix" {
  description = "Short platform name used to build resource names."
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging or prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region for data resources."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix that makes globally-unique names collision-free."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID, used by the extended auditing policy."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "data_subnet_id" {
  description = "Subnet hosting the private endpoints."
  type        = string
}

variable "apps_subnet_id" {
  description = "Application subnet allowed through the storage network rules in production."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Map of service key to private DNS zone ID, from the network module."
  type        = map(string)
}

variable "database_name" {
  description = "Name of the application database."
  type        = string
  default     = "appdb"
}

variable "prod_sku_name" {
  description = "Database SKU in production. Business Critical provides local SSD and a read replica."
  type        = string
  default     = "BC_Gen5_4"
}

variable "nonprod_sku_name" {
  description = "Database SKU outside production."
  type        = string
  default     = "GP_S_Gen5_2"
}

variable "max_size_gb" {
  description = "Maximum database size in GB."
  type        = number
  default     = 100
}

variable "sql_admin_group_name" {
  description = "Display name of the Entra ID group that administers SQL."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the Entra ID group that administers SQL."
  type        = string
}

variable "tde_key_vault_key_id" {
  description = "Key Vault key ID for customer-managed TDE. Empty falls back to a service-managed key."
  type        = string
  default     = ""
}

variable "workload_principal_ids" {
  description = "Principal IDs of workload identities granted database access."
  type        = list(string)
  default     = []
}

variable "security_alert_emails" {
  description = "Addresses notified by SQL Advanced Threat Protection."
  type        = list(string)
  default     = []
}

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public CIDRs allowed through the storage account network rules (office, VPN,
    CI egress). The rules are default-deny in every environment.
  EOT
  type        = list(string)
  default     = []
}

variable "storage_containers" {
  description = "Blob containers to create for platform components."
  type        = list(string)
  default     = ["loki-chunks", "loki-ruler", "tempo-traces", "velero-backups"]
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for SQL diagnostics and auditing."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
