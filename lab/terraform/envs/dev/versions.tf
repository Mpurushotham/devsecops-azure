terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }

  # Remote state lives in the bootstrap-created storage account. Locking is via
  # the blob lease, and `use_azuread_auth` means no storage account key is
  # needed — the pipeline's OIDC identity is authorised through RBAC instead.
  #
  # Values are supplied by `terraform init -backend-config=backend.hcl` so the
  # same code can target different subscriptions (see Makefile).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {
    key_vault {
      # Non-prod vaults are purged on destroy so re-running the lab does not
      # collide with a soft-deleted name.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}
