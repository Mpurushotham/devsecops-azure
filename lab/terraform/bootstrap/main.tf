# =============================================================================
# Bootstrap — the chicken-and-egg layer
# =============================================================================
# Everything else in lab/terraform stores state remotely. This root module
# creates that storage, and is the only one that keeps its state locally (then
# migrates itself into the container it just created).
#
# Run once per subscription:
#   terraform init && terraform apply
#   terraform init -migrate-state    # move local state into the new backend
#
# It also creates the GitHub OIDC federation that lets pipelines run Terraform
# with no stored Azure credential — the single highest-value secret to
# eliminate, because a leaked service principal password grants standing access
# to the whole subscription (ADR-004).
# =============================================================================

locals {
  common_tags = {
    platform    = var.name_prefix
    purpose     = "terraform-state"
    managed-by  = "terraform"
    environment = "shared"
    # State contains resource IDs and, unavoidably, some secret values.
    data-class = "confidential"
  }
}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.name_prefix}-tfstate"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "tfstate" {
  name                = substr(replace("st${var.name_prefix}tfstate${var.unique_suffix}", "-", ""), 0, 24)
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # No account keys: pipelines authenticate with their OIDC identity and the
  # Storage Blob Data Contributor role. A leaked key would otherwise grant
  # write access to every environment's state at once.
  shared_access_key_enabled = false

  blob_properties {
    versioning_enabled = true

    # State corruption is recoverable only if prior versions survive.
    delete_retention_policy {
      days = 90
    }

    container_delete_retention_policy {
      days = 90
    }
  }

  # State is the most sensitive artefact the platform produces — it contains
  # every resource ID and any value Terraform had to read. Default-deny, with
  # access granted only to named CIDRs (self-hosted runner egress, office/VPN).
  #
  # GitHub-hosted runners have no stable egress IP, which is precisely why this
  # repo's plan/apply jobs are expected to run on self-hosted runners in the
  # platform VNet. See docs/DECISIONS.md ADR-006.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.state_allowed_ip_ranges
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "tfstate" {
  for_each = toset(var.environments)

  name                  = "tfstate-${each.value}"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Accidental deletion of the state account is unrecoverable — the lock makes it
# a two-step, deliberate action.
resource "azurerm_management_lock" "tfstate" {
  count = var.enable_delete_lock ? 1 : 0

  name       = "lock-tfstate"
  scope      = azurerm_storage_account.tfstate.id
  lock_level = "CanNotDelete"
  notes      = "Terraform state — deleting this destroys the record of every environment."
}

# ── GitHub OIDC federation for the Terraform pipeline ────────────────────────
resource "azurerm_user_assigned_identity" "terraform" {
  for_each = toset(var.environments)

  name                = "id-${var.name_prefix}-tf-${each.value}"
  location            = azurerm_resource_group.tfstate.location
  resource_group_name = azurerm_resource_group.tfstate.name
  tags                = merge(local.common_tags, { environment = each.value })
}

# Plan runs on pull_request, apply runs on the environment. Two subjects means
# a PR from a fork can never obtain the identity that is allowed to apply.
resource "azurerm_federated_identity_credential" "terraform_environment" {
  for_each = toset(var.environments)

  name                = "fic-tf-env-${each.value}"
  resource_group_name = azurerm_resource_group.tfstate.name
  parent_id           = azurerm_user_assigned_identity.terraform[each.value].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository}:environment:${each.value}"
}

resource "azurerm_federated_identity_credential" "terraform_pull_request" {
  for_each = toset(var.environments)

  name                = "fic-tf-pr-${each.value}"
  resource_group_name = azurerm_resource_group.tfstate.name
  parent_id           = azurerm_user_assigned_identity.terraform[each.value].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository}:pull_request"
}

# The pipeline identity needs to read and write its own environment's state.
resource "azurerm_role_assignment" "terraform_state_contributor" {
  for_each = toset(var.environments)

  scope                = azurerm_storage_container.tfstate[each.value].resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform[each.value].principal_id
}

# Owner rather than Contributor: Terraform creates role assignments (workload
# identity, AcrPull, Key Vault RBAC), and Contributor cannot do that. This is a
# deliberate, documented trade-off — the mitigation is that the identity is only
# assumable from this repository, and only from a protected environment.
resource "azurerm_role_assignment" "terraform_subscription_owner" {
  for_each = toset(var.environments)

  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Owner"
  principal_id         = azurerm_user_assigned_identity.terraform[each.value].principal_id

  # Guard rail: the identity cannot hand out Owner to anyone else.
  condition_version = "2.0"
  condition         = <<-COND
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      )
      OR
      (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidNotEquals {${var.owner_role_definition_id}}
      )
    )
  COND
}
