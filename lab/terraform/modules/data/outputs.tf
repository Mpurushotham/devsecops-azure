output "resource_group_name" {
  description = "Resource group holding the data resources."
  value       = azurerm_resource_group.data.name
}

output "sql_server_id" {
  description = "Resource ID of the SQL server."
  value       = azurerm_mssql_server.main.id
}

output "sql_server_fqdn" {
  description = "SQL server FQDN. Resolves to the private endpoint inside the VNet."
  value       = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "database_name" {
  description = "Name of the application database."
  value       = azurerm_mssql_database.main.name
}

output "connection_string_template" {
  description = <<-EOT
    Passwordless connection string for the app. Authentication is the pod's
    workload identity — there is deliberately no password placeholder here.
  EOT
  value       = "Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.main.name};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
}

output "storage_account_name" {
  description = "Platform storage account name (Loki, Tempo, Velero)."
  value       = azurerm_storage_account.platform.name
}

output "storage_account_id" {
  description = "Platform storage account resource ID."
  value       = azurerm_storage_account.platform.id
}

output "storage_container_names" {
  description = "Names of the created blob containers."
  value       = [for c in azurerm_storage_container.this : c.name]
}
