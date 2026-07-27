terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Local state on purpose. The sandbox exists to be created and destroyed on a
  # subscription with no shared team backend; bootstrapping remote state would
  # cost more than the environment it tracks. Every other environment uses the
  # azurerm backend from lab/terraform/bootstrap.
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # The platform storage account sets shared_access_key_enabled = false, so the
  # provider's own data-plane calls must authenticate with Entra too. Without
  # this the apply fails with KeyBasedAuthenticationNotPermitted while polling
  # the blob service — the provider trying to use a key the account rejects.
  storage_use_azuread = true

  features {
    key_vault {
      # A sandbox is recreated often; a soft-deleted vault would block the name
      # on the next apply.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # `make destroy` must actually work here.
      prevent_deletion_if_contains_resources = false
    }
  }
}
