output "state_resource_group_name" {
  description = "Resource group holding Terraform state."
  value       = azurerm_resource_group.tfstate.name
}

output "state_storage_account_name" {
  description = "Storage account name for the -backend-config=storage_account_name argument."
  value       = azurerm_storage_account.tfstate.name
}

output "state_container_names" {
  description = "Map of environment to state container name."
  value       = { for k, c in azurerm_storage_container.tfstate : k => c.name }
}

output "terraform_identity_client_ids" {
  description = "Map of environment to pipeline identity client ID (azure/login client-id input)."
  value       = { for k, id in azurerm_user_assigned_identity.terraform : k => id.client_id }
}

output "backend_config_hcl" {
  description = "Ready-to-use backend.hcl content per environment."
  value = {
    for env in var.environments : env => join("\n", [
      "resource_group_name  = \"${azurerm_resource_group.tfstate.name}\"",
      "storage_account_name = \"${azurerm_storage_account.tfstate.name}\"",
      "container_name       = \"${azurerm_storage_container.tfstate[env].name}\"",
      "key                  = \"${env}.terraform.tfstate\"",
      "use_azuread_auth     = true",
    ])
  }
}
