variable "name_prefix" {
  description = "Short platform name used to build resource names."
  type        = string
  default     = "rebtel-plat"
}

variable "location" {
  description = "Primary Azure region."
  type        = string
  default     = "swedencentral"
}

variable "subscription_id" {
  description = "Azure subscription ID for this environment."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix for globally-unique resource names (ACR, Key Vault, SQL, storage)."
  type        = string
}

variable "vnet_cidr" {
  description = "Address space of the production spoke VNet."
  type        = string
  default     = "10.10.0.0/16"
}

variable "kubernetes_version" {
  description = "AKS minor version. Must still be in mainstream support — see `az aks get-versions`."
  type        = string
  default     = "1.34"
}

variable "cluster_admin_group_object_ids" {
  description = "Entra ID groups with cluster-admin. Break-glass only."
  type        = list(string)
  default     = []
}

variable "platform_admin_group_object_ids" {
  description = "Entra ID groups administering Key Vault and Grafana."
  type        = list(string)
  default     = []
}

variable "sql_admin_group_name" {
  description = "Display name of the Entra ID group administering SQL."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the Entra ID group administering SQL."
  type        = string
}

variable "database_name" {
  description = "Application database name."
  type        = string
  default     = "payments"
}

variable "github_repository" {
  description = "GitHub repo in owner/name form for OIDC federation."
  type        = string
  default     = ""
}

variable "acr_geo_replications" {
  description = "Regions to geo-replicate the production registry to."
  type        = list(string)
  default     = []
}

variable "enable_windows_pool" {
  description = "Create the Windows node pool for .NET Framework lift-and-shift."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable NSG flow logs with traffic analytics."
  type        = bool
  default     = false
}

variable "network_watcher_name" {
  description = "Regional Network Watcher name (required when flow logs are enabled)."
  type        = string
  default     = ""
}

variable "flow_log_storage_account_id" {
  description = "Storage account for raw flow logs (required when flow logs are enabled)."
  type        = string
  default     = ""
}

variable "cost_centre" {
  description = "Cost centre tag for chargeback reporting."
  type        = string
  default     = "platform-engineering"
}

variable "owning_team" {
  description = "Team accountable for these resources."
  type        = string
  default     = "platform-engineering"
}

# ── Alerting and third-party observability ───────────────────────────────────
variable "pagerduty_webhook_url" {
  description = "PagerDuty Events API webhook."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Slack webhook for non-paging alerts."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oncall_emails" {
  description = "Fallback paging recipients and SQL threat-detection notifications."
  type        = list(string)
  default     = []
}

variable "elastic_api_key" {
  description = "Elastic Cloud API key, stored in Key Vault."
  type        = string
  default     = ""
  sensitive   = true
}

variable "datadog_api_key" {
  description = "Datadog API key, stored in Key Vault."
  type        = string
  default     = ""
  sensitive   = true
}

variable "allowed_ip_ranges" {
  description = "Public CIDRs (office, VPN, CI egress) allowed through Key Vault and storage network ACLs, which are default-deny."
  type        = list(string)
  default     = []
}
