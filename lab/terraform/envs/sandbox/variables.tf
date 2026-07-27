variable "name_prefix" {
  description = "Short platform name used to build resource names."
  type        = string
  default     = "rebtel-lab"
}

variable "location" {
  description = "Azure region. Must have vCPU quota for the node pool."
  type        = string
  default     = "swedencentral"
}

variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix for globally-unique names (ACR, Key Vault, storage)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.unique_suffix))
    error_message = "unique_suffix must be 3-8 lowercase alphanumeric characters."
  }
}

variable "vnet_cidr" {
  description = "Address space of the sandbox VNet."
  type        = string
  default     = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "AKS minor version. Must still be in mainstream support — see `az aks get-versions`."
  type        = string
  default     = "1.34"
}

variable "node_vm_size" {
  description = <<-EOT
    Node size. Standard_B2s_v2 is 2 vCPU / 8 GiB — two of them consume the
    entire 4 vCPU regional quota on this subscription.

    Not every size is offered on every subscription: Standard_B2s (v1) is
    rejected here with "The VM size ... is not allowed in your subscription".
    Confirm before changing:
      az vm list-skus -l <region> --size Standard_B --query "[].name" -o tsv
  EOT
  type        = string
  default     = "Standard_B2s_v2"
}

variable "api_server_authorized_ip_ranges" {
  # No default: a public API server open to the internet must never be the
  # result of forgetting a variable.
  description = "CIDRs allowed to reach the API server, Key Vault and storage. Normally your public IP as a /32."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0
    error_message = "Supply at least one CIDR — typically \"<your-public-ip>/32\"."
  }
}

variable "enable_sql" {
  description = "Provision Azure SQL. Off by default: it is the largest avoidable cost in this environment."
  type        = bool
  default     = false
}

variable "database_name" {
  description = "Application database name, when SQL is enabled."
  type        = string
  default     = "payments"
}

variable "sql_admin_group_name" {
  description = "Entra ID principal name for the SQL administrator. Defaults to the signed-in user."
  type        = string
  default     = "sandbox-sql-admin"
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the SQL administrator. Empty uses the signed-in user."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repo in owner/name form for OIDC federation. Empty disables the deploy identity."
  type        = string
  default     = ""
}

variable "monthly_budget_eur" {
  description = "Subscription budget that raises alerts at 50%, 80% and forecast 100%. Zero disables it."
  type        = number
  default     = 50
}

variable "budget_alert_emails" {
  description = "Recipients for budget alerts."
  type        = list(string)
  default     = []
}

variable "cost_centre" {
  description = "Cost centre tag."
  type        = string
  default     = "platform-lab"
}

variable "owning_team" {
  description = "Team accountable for these resources."
  type        = string
  default     = "platform-engineering"
}
