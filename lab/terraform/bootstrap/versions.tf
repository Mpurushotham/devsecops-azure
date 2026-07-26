terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }

  # Intentionally local: this module creates the remote backend that every
  # other root module uses. Run `terraform init -migrate-state` after the first
  # apply to move this state into the container it just created.
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {}
}
