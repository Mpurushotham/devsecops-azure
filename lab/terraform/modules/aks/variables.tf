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
  description = "Azure region for the cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "AKS minor version. Patch drift is handled by the auto-upgrade channel."
  type        = string
  default     = "1.31"
}

variable "tenant_id" {
  description = "Entra ID tenant used for cluster RBAC."
  type        = string
}

variable "admin_group_object_ids" {
  description = "Entra ID group object IDs granted cluster-admin. Keep this to break-glass groups only."
  type        = list(string)
  default     = []
}

variable "vnet_id" {
  description = "Resource ID of the spoke VNet (needed for the Network Contributor assignment)."
  type        = string
}

variable "system_subnet_id" {
  description = "Subnet for the system node pool."
  type        = string
}

variable "apps_subnet_id" {
  description = "Subnet for application, spot and Windows node pools."
  type        = string
}

variable "pod_cidr" {
  description = "Overlay CIDR for pod IPs. Must not overlap the VNet or service CIDR."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes ClusterIP services."
  type        = string
  default     = "172.16.0.0/16"
}

variable "private_cluster_enabled" {
  description = "Keep the API server off the public internet. Requires a self-hosted runner or bastion to deploy."
  type        = bool
  default     = true
}

variable "api_server_authorized_ip_ranges" {
  description = <<-EOT
    CIDRs allowed to reach a public API server (office, VPN, CI egress). Required
    when private_cluster_enabled is false — a plan-time precondition rejects an
    empty list rather than exposing the control plane to the internet.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.api_server_authorized_ip_ranges : can(cidrhost(c, 0))])
    error_message = "api_server_authorized_ip_ranges must contain valid CIDR blocks."
  }
}

variable "acr_id" {
  description = "ACR resource ID to grant AcrPull to the kubelet identity. Empty disables the assignment."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID for the monitoring addon, Defender and diagnostics."
  type        = string
}

# ── System pool ──────────────────────────────────────────────────────────────
variable "system_pool_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_pool_min_count" {
  description = "Minimum system nodes."
  type        = number
  default     = 3
}

variable "system_pool_max_count" {
  description = "Maximum system nodes."
  type        = number
  default     = 6
}

# ── Application pool ─────────────────────────────────────────────────────────
variable "app_pool_vm_size" {
  description = "VM size for the application node pool."
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "app_pool_min_count" {
  description = "Minimum application nodes — the floor that absorbs a spike before the autoscaler reacts."
  type        = number
  default     = 3
}

variable "app_pool_max_count" {
  description = "Maximum application nodes. Sized for peak seasonal traffic."
  type        = number
  default     = 20
}

# ── Spot pool ────────────────────────────────────────────────────────────────
variable "enable_spot_pool" {
  description = "Create a spot node pool for interruptible batch workloads."
  type        = bool
  default     = false
}

variable "spot_pool_vm_size" {
  description = "VM size for the spot node pool."
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "spot_pool_max_count" {
  description = "Maximum spot nodes. Minimum is always 0 so the pool costs nothing when idle."
  type        = number
  default     = 10
}

# ── Windows pool ─────────────────────────────────────────────────────────────
variable "enable_windows_pool" {
  description = "Create a Windows node pool for lift-and-shift .NET Framework workloads."
  type        = bool
  default     = false
}

variable "windows_pool_vm_size" {
  description = "VM size for the Windows node pool."
  type        = string
  default     = "Standard_D8ds_v5"
}

variable "windows_pool_min_count" {
  description = "Minimum Windows nodes."
  type        = number
  default     = 2
}

variable "windows_pool_max_count" {
  description = "Maximum Windows nodes."
  type        = number
  default     = 8
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
