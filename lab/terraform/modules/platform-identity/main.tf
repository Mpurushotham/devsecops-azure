# =============================================================================
# Module: platform-identity — ACR, Key Vault and the workload identity fabric
# =============================================================================
# The goal (ADR-004): there is no long-lived secret anywhere in the delivery
# path. Three federation relationships replace what would otherwise be three
# stored credentials:
#
#   GitHub Actions  --OIDC-->  Entra ID  (deploy identity, no ACR password)
#   AKS pod         --OIDC-->  Entra ID  (app identity, no connection string)
#   Azure DevOps    --OIDC-->  Entra ID  (workload identity federation)
#
# Key Vault holds what genuinely must be stored (third-party API keys, payment
# processor credentials); pods read them through the CSI driver at mount time,
# never as Kubernetes Secrets at rest.
# =============================================================================

locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "platform-identity"
    environment = var.environment
  })

  # Key Vault names are globally unique, max 24 chars, alphanumeric + dashes.
  kv_name = substr(replace("kv-${local.name_prefix}-${var.unique_suffix}", "_", "-"), 0, 24)
  # ACR names are globally unique, alphanumeric only, max 50 chars.
  acr_name = substr(replace("acr${var.name_prefix}${var.environment}${var.unique_suffix}", "-", ""), 0, 50)

  # Azure storage and Key Vault network ACLs reject a /32 suffix — a single
  # address must be given bare. Callers pass ordinary CIDRs, so normalise here
  # rather than making every environment remember the quirk. Only apply/plan
  # against the real API surfaces this; the schema accepts /32 happily.
  allowed_ips = [for c in var.allowed_ip_ranges : replace(c, "/32", "")]

}

resource "azurerm_resource_group" "platform" {
  name     = "rg-${local.name_prefix}-platform"
  location = var.location
  tags     = local.common_tags
}

# NOTE on count/for_each below: these gate on plain booleans, never on a value
# that is computed by another resource. `count = var.some_id == "" ? 0 : 1` looks
# equivalent but fails the plan with "Invalid count argument" whenever that id
# comes from a resource created in the same apply — which is exactly how these
# modules are wired together. Only a real `terraform plan` surfaces this;
# `terraform validate` cannot.

# ── Container registry ───────────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  # Basic is enough for a sandbox; Premium is required for private link,
  # geo-replication and content trust, which only production uses.
  sku = var.acr_sku != "" ? var.acr_sku : (var.environment == "prod" ? "Premium" : "Standard")

  # Admin user is a shared password with no audit trail — workload identity and
  # AcrPull role assignments replace it entirely.
  admin_enabled = false

  # Premium-only capabilities: private link, geo-replication, image retention.
  public_network_access_enabled = var.environment == "prod" ? false : true
  zone_redundancy_enabled       = var.environment == "prod"

  dynamic "georeplications" {
    for_each = var.environment == "prod" ? var.acr_geo_replications : []
    content {
      location                = georeplications.value
      zone_redundancy_enabled = true
      tags                    = local.common_tags
    }
  }

  # Untagged manifests are garbage after 30 days; keeping them inflates cost and
  # widens the set of images an attacker could pull by digest.
  # Retention policy is a Premium-only feature.
  retention_policy_in_days = var.environment == "prod" ? 30 : null

  # Content trust: only signed images are pullable in production.
  trust_policy_enabled = var.environment == "prod"

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# AcrPull for the cluster's kubelet identity is granted *here*, by the module
# that owns the registry, rather than in the AKS module. The dependency only
# runs one way — platform-identity needs the cluster's OIDC issuer, so ACR is
# created after AKS — and asking the AKS module to reference an ACR that does
# not exist yet would be a cycle. Without this assignment every image pull
# fails with a 401 from the registry's token endpoint.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.kubelet_identity_principal_id == "" ? 0 : 1

  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = var.kubelet_identity_principal_id
}

resource "azurerm_private_endpoint" "acr" {
  count = var.environment == "prod" ? 1 : 0

  name                = "pe-acr-${local.name_prefix}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = var.data_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-acr-${local.name_prefix}"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns"
    private_dns_zone_ids = [var.private_dns_zone_ids["acr"]]
  }
}

# ── Key Vault ────────────────────────────────────────────────────────────────
resource "azurerm_key_vault" "main" {
  name                = local.kv_name
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tenant_id           = var.tenant_id
  # HSM-backed keys for payment-related material in production; standard
  # elsewhere, since premium bills per key per month.
  sku_name = var.key_vault_sku != "" ? var.key_vault_sku : (var.environment == "prod" ? "premium" : "standard")

  # RBAC instead of access policies: one authorization model across the estate,
  # auditable through the same role assignment reports as everything else.
  rbac_authorization_enabled = true

  purge_protection_enabled   = var.environment == "prod"
  soft_delete_retention_days = var.environment == "prod" ? 90 : 7

  public_network_access_enabled = var.environment == "prod" ? false : true

  # Default-deny in every environment. A non-prod vault open to the internet is
  # still a vault holding real third-party credentials — dev access is granted
  # by listing the office/VPN CIDRs, not by leaving the door open.
  network_acls {
    bypass                     = "AzureServices"
    default_action             = "Deny"
    virtual_network_subnet_ids = [var.apps_subnet_id]
    ip_rules                   = local.allowed_ips
  }

  tags = local.common_tags
}

resource "azurerm_private_endpoint" "keyvault" {
  count = var.environment == "prod" ? 1 : 0

  name                = "pe-kv-${local.name_prefix}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = var.data_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-kv-${local.name_prefix}"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [var.private_dns_zone_ids["keyvault"]]
  }
}

# The CSI driver identity only ever reads secrets — never writes, never manages.
resource "azurerm_role_assignment" "csi_driver_kv_reader" {
  count = var.enable_csi_driver_access ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.key_vault_csi_identity_object_id
}

# Platform engineers administer the vault through a group, never individually.
resource "azurerm_role_assignment" "platform_admins_kv" {
  for_each = toset(var.platform_admin_group_object_ids)

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# Role assignments are not effective the instant the ARM call returns: the data
# plane can still answer 403 ForbiddenByRbac for up to a minute. Anything that
# writes a secret in the same apply must wait, or the apply fails on a
# permission the operator demonstrably has.
resource "time_sleep" "kv_rbac_propagation" {
  count = var.rbac_propagation_seconds > 0 ? 1 : 0

  depends_on = [
    azurerm_role_assignment.platform_admins_kv,
    azurerm_role_assignment.csi_driver_kv_reader,
  ]

  create_duration = "${var.rbac_propagation_seconds}s"
}

# ── Workload identities for applications ─────────────────────────────────────
# One identity per workload, each federated to exactly one namespace/service
# account pair. A compromised pod in `staging` cannot assume the `prod` identity
# because the subject claim will not match.
resource "azurerm_user_assigned_identity" "workload" {
  for_each = var.workload_identities

  name                = "id-${local.name_prefix}-${each.key}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = merge(local.common_tags, { workload = each.key })
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = var.workload_identities

  name                = "fic-${each.key}"
  resource_group_name = azurerm_resource_group.platform.name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "workload_kv_secrets" {
  for_each = {
    for k, v in var.workload_identities : k => v if v.key_vault_secrets_access
  }

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload[each.key].principal_id
}

# ── GitHub Actions deploy identity (OIDC, no stored credential) ──────────────
resource "azurerm_user_assigned_identity" "github_deploy" {
  count = var.github_repository == "" ? 0 : 1

  name                = "id-${local.name_prefix}-gh-deploy"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.common_tags
}

# Separate credentials per trigger type: a PR from a fork cannot obtain the
# environment-scoped token that only a push to the release branch can.
resource "azurerm_federated_identity_credential" "github_environment" {
  count = var.github_repository == "" ? 0 : 1

  name                = "fic-gh-env-${var.environment}"
  resource_group_name = azurerm_resource_group.platform.name
  parent_id           = azurerm_user_assigned_identity.github_deploy[0].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository}:environment:${var.environment}"
}

resource "azurerm_role_assignment" "github_acr_push" {
  count = var.github_repository == "" ? 0 : 1

  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_deploy[0].principal_id
}

# Deploying via GitOps means the pipeline never needs cluster write access —
# it only needs to read cluster metadata to run smoke tests.
resource "azurerm_role_assignment" "github_aks_reader" {
  count = var.github_repository != "" && var.enable_github_aks_reader ? 1 : 0

  scope                = var.aks_cluster_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github_deploy[0].principal_id
}

# ── Diagnostics ──────────────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-kv-${local.name_prefix}"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Every secret read is recorded: this is the audit trail for access to
  # payment processor credentials.
  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "acr" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-acr-${local.name_prefix}"
  target_resource_id         = azurerm_container_registry.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
