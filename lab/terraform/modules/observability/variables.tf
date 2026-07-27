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
  description = "Azure region for observability resources."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID, scoped to Grafana's Monitoring Reader assignment."
  type        = string
}

variable "aks_cluster_id" {
  description = "AKS cluster resource ID to associate with the Prometheus DCR. Empty skips the association."
  type        = string
  default     = ""
}

variable "key_vault_id" {
  description = "Key Vault that receives observability credentials. Empty disables secret creation."
  type        = string
  default     = ""
}

variable "prod_log_retention_days" {
  description = "Log Analytics retention in production. Must cover the audit evidence window."
  type        = number
  default     = 180
}

variable "nonprod_daily_quota_gb" {
  description = "Daily ingestion cap outside production, so a log loop cannot burn the budget."
  type        = number
  default     = 5
}

variable "prod_trace_sampling_percentage" {
  description = "Head sampling rate for traces in production. Errors are always kept by tail sampling."
  type        = number
  default     = 10

  validation {
    condition     = var.prod_trace_sampling_percentage > 0 && var.prod_trace_sampling_percentage <= 100
    error_message = "prod_trace_sampling_percentage must be between 1 and 100."
  }
}

variable "enable_managed_grafana" {
  description = "Provision Azure Managed Grafana."
  type        = bool
  default     = true
}

variable "grafana_admin_group_object_ids" {
  description = "Entra ID groups granted Grafana Admin."
  type        = list(string)
  default     = []
}

# ── Alerting ─────────────────────────────────────────────────────────────────
variable "enable_slo_alerts" {
  description = "Create the SLO burn-rate and latency alert rules."
  type        = bool
  default     = true
}

variable "slo_fast_burn_error_rate" {
  description = "Error rate over 1h that constitutes a fast burn of the error budget (pages on-call)."
  type        = number
  default     = 0.05
}

variable "slo_slow_burn_error_rate" {
  description = "Error rate over 6h that constitutes a slow burn (opens a ticket)."
  type        = number
  default     = 0.01
}

variable "slo_p99_latency_ms" {
  description = "p99 latency SLO target in milliseconds."
  type        = number
  default     = 1000
}

variable "pagerduty_webhook_url" {
  description = "PagerDuty Events API webhook for the paging action group."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Slack webhook for the ticketing action group."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oncall_emails" {
  description = "Fallback email recipients for paging alerts."
  type        = list(string)
  default     = []
}

# ── Third-party observability ────────────────────────────────────────────────
variable "elastic_api_key" {
  description = "Elastic Cloud API key, stored in Key Vault for the log shipper. Empty skips it."
  type        = string
  default     = ""
  sensitive   = true
}

variable "datadog_api_key" {
  description = "Datadog API key, stored in Key Vault for the agent. Empty skips it."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "enable_aks_prometheus_scrape" {
  description = "Associate the Prometheus data collection rule with aks_cluster_id."
  type        = bool
  default     = true
}

variable "enable_key_vault_secrets" {
  description = "Write the App Insights connection string into key_vault_id."
  type        = bool
  default     = true
}
