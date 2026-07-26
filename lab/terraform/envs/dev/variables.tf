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
  description = "Address space of the dev spoke VNet."
  type        = string
  default     = "10.30.0.0/16"
}

variable "kubernetes_version" {
  description = "AKS minor version."
  type        = string
  default     = "1.31"
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
variable "allowed_ip_ranges" {
  description = "Public CIDRs (office, VPN, CI egress) allowed through Key Vault and storage network ACLs, which are default-deny."
  type        = list(string)
  default     = []
}

variable "api_server_authorized_ip_ranges" {
  # Deliberately has no default: this environment runs a public API server, so
  # an apply must not be possible without stating who may reach it. The AKS
  # module additionally enforces this with a plan-time precondition.
  description = "CIDRs allowed to reach the public AKS API server (office, VPN, CI egress)."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0
    error_message = "A public API server must be restricted to explicit CIDRs."
  }
}
