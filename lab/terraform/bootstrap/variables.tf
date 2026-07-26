variable "name_prefix" {
  description = "Short platform name used to build resource names."
  type        = string
  default     = "rebtel-plat"
}

variable "location" {
  description = "Azure region for the state storage account."
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
  description = "Short suffix making the storage account name globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.unique_suffix))
    error_message = "unique_suffix must be 3-8 lowercase alphanumeric characters."
  }
}

variable "environments" {
  description = "Environments to create a state container and pipeline identity for."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

variable "github_repository" {
  description = "GitHub repo in owner/name form allowed to federate into these identities."
  type        = string
}

variable "state_allowed_ip_ranges" {
  # No default: the state account is default-deny, so an operator must state who
  # may reach it. Leaving it empty locks everyone out, including the pipeline —
  # which is a safer failure than a state account open to the internet.
  description = "Public CIDRs allowed to reach the Terraform state account (runner egress, office, VPN)."
  type        = list(string)

  validation {
    condition     = length(var.state_allowed_ip_ranges) > 0
    error_message = "At least one CIDR must be allowed, or nothing can read or write state."
  }
}

variable "enable_delete_lock" {
  description = "Apply a CanNotDelete lock to the state storage account."
  type        = bool
  default     = true
}

variable "owner_role_definition_id" {
  description = "GUID of the built-in Owner role, excluded from what the pipeline identity may grant."
  type        = string
  default     = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
}
