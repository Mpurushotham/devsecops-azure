output "resource_group_name" {
  description = "Resource group holding the network resources."
  value       = azurerm_resource_group.network.name
}

output "vnet_id" {
  description = "Resource ID of the spoke VNet."
  value       = azurerm_virtual_network.spoke.id
}

output "vnet_name" {
  description = "Name of the spoke VNet."
  value       = azurerm_virtual_network.spoke.name
}

output "subnet_ids" {
  description = "Map of subnet purpose to subnet resource ID."
  value = {
    ingress = azurerm_subnet.ingress.id
    system  = azurerm_subnet.system.id
    apps    = azurerm_subnet.apps.id
    data    = azurerm_subnet.data.id
  }
}

output "subnet_cidrs" {
  description = "Map of subnet purpose to CIDR, for NetworkPolicy and firewall rules."
  value = {
    ingress = azurerm_subnet.ingress.address_prefixes[0]
    system  = azurerm_subnet.system.address_prefixes[0]
    apps    = azurerm_subnet.apps.address_prefixes[0]
    data    = azurerm_subnet.data.address_prefixes[0]
  }
}

output "nat_egress_ip" {
  description = <<-EOT
    Static outbound IP — the address partners and payment processors allowlist.
    Empty when the NAT gateway is disabled, in which case egress uses ephemeral
    load-balancer addresses and is not allowlistable.
  EOT
  value       = try(azurerm_public_ip.nat[0].ip_address, "")
}

output "private_dns_zone_ids" {
  description = "Map of service key to private DNS zone resource ID, consumed by the data module."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}
