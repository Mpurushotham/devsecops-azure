variable "name_prefix" {
  description = "Short platform name used to build resource names (e.g. \"rebtel-plat\")."
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
  description = "Azure region for all network resources."
  type        = string
}

variable "vnet_cidr" {
  description = "Address space of the spoke VNet. Must be at least a /20 to fit the subnet plan."
  type        = string

  validation {
    condition     = tonumber(split("/", var.vnet_cidr)[1]) <= 20
    error_message = "vnet_cidr must be /20 or larger (smaller prefix number) to fit the subnet plan."
  }
}

variable "dns_servers" {
  description = "Custom DNS servers for the VNet. Empty list uses Azure-provided DNS."
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "Zones for zone-redundant public IPs."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "enable_flow_logs" {
  description = "Enable NSG flow logs with traffic analytics. Required for payment-traffic audit evidence."
  type        = bool
  default     = false
}

variable "network_watcher_name" {
  description = "Name of the regional Network Watcher instance (required when enable_flow_logs is true)."
  type        = string
  default     = ""
}

variable "network_watcher_resource_group" {
  description = "Resource group holding the Network Watcher (usually NetworkWatcherRG)."
  type        = string
  default     = "NetworkWatcherRG"
}

variable "flow_log_storage_account_id" {
  description = "Storage account resource ID for raw flow logs (required when enable_flow_logs is true)."
  type        = string
  default     = ""
}

variable "flow_log_retention_days" {
  description = "Retention for raw NSG flow logs."
  type        = number
  default     = 90
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID used by traffic analytics."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_guid" {
  description = "Log Analytics workspace GUID (workspace_id attribute) used by traffic analytics."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Provision a NAT gateway for deterministic, allowlistable egress (ADR-003).
    It carries an hourly charge plus data processing, so it can be disabled for
    a sandbox — at the cost of losing the static egress IP. The AKS module's
    outbound_type must be set to loadBalancer to match.
  EOT
  type        = bool
  default     = true
}

variable "enable_private_dns_zones" {
  description = <<-EOT
    Create the private DNS zones used for private-endpoint resolution. Only
    needed where private endpoints are actually deployed; each zone carries a
    small monthly charge.
  EOT
  type        = bool
  default     = true
}
