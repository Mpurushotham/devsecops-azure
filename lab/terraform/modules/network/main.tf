# =============================================================================
# Module: network — Azure hub-and-spoke landing zone for the AKS platform
# =============================================================================
# Segmentation model (ADR-002): one spoke VNet per environment, four subnets
# with distinct trust levels. Everything is deny-by-default at the NSG layer;
# the AKS NetworkPolicy layer enforces pod-to-pod rules inside the cluster.
#
#   ingress   — public entry (App Gateway / ingress controller LBs)
#   system    — AKS system node pool (CoreDNS, metrics-server, CNI)
#   apps      — AKS application node pools (customer traffic)
#   data      — private endpoints only (SQL, Key Vault, ACR, Storage)
#
# Payment-adjacent traffic never leaves the VNet: SQL, Key Vault and ACR are
# reachable exclusively through private endpoints in the data subnet, and
# egress is forced through a NAT gateway with a static, allowlistable IP.
# =============================================================================

locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  # Private DNS zones needed for private-endpoint name resolution. Without
  # these, clients resolve the public CNAME and the private endpoint is unused.
  private_dns_zones = {
    sql        = "privatelink.database.windows.net"
    keyvault   = "privatelink.vaultcore.azure.net"
    acr        = "privatelink.azurecr.io"
    blob       = "privatelink.blob.core.windows.net"
    servicebus = "privatelink.servicebus.windows.net"
  }

  common_tags = merge(var.tags, {
    module      = "network"
    environment = var.environment
  })
}

resource "azurerm_resource_group" "network" {
  name     = "rg-${local.name_prefix}-network"
  location = var.location
  tags     = local.common_tags
}

# ── Spoke VNet ───────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = [var.vnet_cidr]
  dns_servers         = var.dns_servers
  tags                = local.common_tags
}

resource "azurerm_subnet" "ingress" {
  name                 = "snet-ingress"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 4, 0)]
}

resource "azurerm_subnet" "system" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 4, 1)]

  service_endpoints = var.subnet_service_endpoints
}

# Sized /20 out of the spoke: Azure CNI overlay assigns pod IPs from a separate
# pod CIDR, but node scale-out during seasonal peaks still consumes node IPs.
resource "azurerm_subnet" "apps" {
  name                 = "snet-aks-apps"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 2, 1)]

  # Required before this subnet can appear in a PaaS resource's network ACL.
  # Without them Azure rejects the ACL with SubnetsHaveNoServiceEndpointsConfigured
  # — a failure that appears only at apply, never at plan.
  service_endpoints = var.subnet_service_endpoints
}

resource "azurerm_subnet" "data" {
  name                 = "snet-data"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 4, 2)]

  private_endpoint_network_policies = "Enabled"
}

# ── NAT gateway: deterministic, allowlistable egress ─────────────────────────
# Payment processors and partner APIs allowlist source IPs. Default AKS
# outbound uses ephemeral LB IPs that change on scale events — a static NAT
# egress IP is a hard requirement for that integration (ADR-003).
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "pip-nat-${local.name_prefix}"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = length(var.availability_zones) > 0 ? var.availability_zones : null
  tags                = local.common_tags
}

resource "azurerm_nat_gateway" "egress" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "natgw-${local.name_prefix}"
  location                = azurerm_resource_group.network.location
  resource_group_name     = azurerm_resource_group.network.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "egress" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.egress[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "apps" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.apps.id
  nat_gateway_id = azurerm_nat_gateway.egress[0].id
}

resource "azurerm_subnet_nat_gateway_association" "system" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.system.id
  nat_gateway_id = azurerm_nat_gateway.egress[0].id
}

# ── NSGs: deny-by-default, explicit allows ───────────────────────────────────
resource "azurerm_network_security_group" "ingress" {
  name                = "nsg-ingress-${local.name_prefix}"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "ingress_allow_https" {
  name                        = "allow-https-inbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.ingress.name
}

# HTTP is accepted only so the ingress controller can 301 to HTTPS; the
# ingress definitions themselves set force-ssl-redirect.
resource "azurerm_network_security_rule" "ingress_allow_http_redirect" {
  name                        = "allow-http-for-redirect"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.ingress.name
}

resource "azurerm_network_security_rule" "ingress_deny_all" {
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.ingress.name
}

resource "azurerm_network_security_group" "apps" {
  name                = "nsg-apps-${local.name_prefix}"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.common_tags
}

# Only the ingress subnet may reach workload ports. East-west traffic between
# namespaces is further restricted by Kubernetes NetworkPolicies.
resource "azurerm_network_security_rule" "apps_allow_from_ingress" {
  name                        = "allow-from-ingress-subnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443", "8080"]
  source_address_prefix       = azurerm_subnet.ingress.address_prefixes[0]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_network_security_rule" "apps_allow_intra_vnet" {
  name                        = "allow-intra-vnet"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_network_security_rule" "apps_deny_internet_inbound" {
  name                        = "deny-internet-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.apps.name
}

resource "azurerm_network_security_group" "data" {
  name                = "nsg-data-${local.name_prefix}"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.common_tags
}

# The data subnet holds private endpoints only: reachable from the cluster,
# never from the internet, and it never initiates outbound connections.
resource "azurerm_network_security_rule" "data_allow_from_cluster" {
  name                        = "allow-from-cluster-subnets"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["1433", "443", "5671", "5672"]
  source_address_prefixes     = [azurerm_subnet.apps.address_prefixes[0], azurerm_subnet.system.address_prefixes[0]]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.data.name
}

resource "azurerm_network_security_rule" "data_deny_all_inbound" {
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.data.name
}

resource "azurerm_network_security_rule" "data_deny_internet_outbound" {
  name                        = "deny-internet-outbound"
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.data.name
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  subnet_id                 = azurerm_subnet.ingress.id
  network_security_group_id = azurerm_network_security_group.ingress.id
}

resource "azurerm_subnet_network_security_group_association" "apps" {
  subnet_id                 = azurerm_subnet.apps.id
  network_security_group_id = azurerm_network_security_group.apps.id
}

resource "azurerm_subnet_network_security_group_association" "system" {
  subnet_id                 = azurerm_subnet.system.id
  network_security_group_id = azurerm_network_security_group.apps.id
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}

# ── Private DNS ──────────────────────────────────────────────────────────────
resource "azurerm_private_dns_zone" "this" {
  for_each = var.enable_private_dns_zones ? local.private_dns_zones : {}

  name                = each.value
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = var.enable_private_dns_zones ? local.private_dns_zones : {}

  name                  = "link-${each.key}-${local.name_prefix}"
  resource_group_name   = azurerm_resource_group.network.name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = local.common_tags
}

# ── Flow logs: required evidence for payment-traffic audits ──────────────────
resource "azurerm_network_watcher_flow_log" "apps" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "flowlog-apps-${local.name_prefix}"
  network_watcher_name = var.network_watcher_name
  resource_group_name  = var.network_watcher_resource_group
  location             = azurerm_resource_group.network.location
  target_resource_id   = azurerm_network_security_group.apps.id
  storage_account_id   = var.flow_log_storage_account_id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = var.log_analytics_workspace_guid
    workspace_region      = azurerm_resource_group.network.location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}
