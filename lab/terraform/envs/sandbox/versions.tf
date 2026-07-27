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

  # Remote state, because CI cannot operate local state. This started as local
  # state on the argument that a disposable environment does not justify a
  # backend — true right up until an Azure DevOps pipeline needed to plan
  # against it, at which point "disposable" and "shared" stopped being
  # compatible.
  #
  # The storage account is created outside Terraform, deliberately: the thing
  # that holds state cannot be managed by the state it holds. Every other
  # environment uses the account that lab/terraform/bootstrap creates.
  backend "azurerm" {
    use_azuread_auth = true
  }
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
