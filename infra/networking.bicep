// Private networking so the Flex Function App can reach the no-public-access storage.
// Creates a VNet (PE subnet + delegated app subnet), private endpoints for
// blob/queue/table, and private DNS zones wired to the VNet.
param location string = resourceGroup().location
param storageAccountName string
param vnetName string = 'odcr-demo-vnet'

var peSubnetName  = 'pe-subnet'
var appSubnetName = 'app-subnet'
var services = [ 'blob', 'queue', 'table' ]

resource stg 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: appSubnetName
        properties: {
          addressPrefix: '10.20.2.0/24'
          delegations: [
            {
              name: 'flexdelegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

// One private DNS zone per storage service
resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for s in services: {
  name: 'privatelink.${s}.${environment().suffixes.storage}'
  location: 'global'
}]

// Link each zone to the VNet so the app resolves storage FQDNs to private IPs
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (s, i) in services: {
  parent: dnsZones[i]
  name: 'link-${s}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

// Private endpoint per service, in the PE subnet
resource privateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for (s, i) in services: {
  name: 'pe-${storageAccountName}-${s}'
  location: location
  properties: {
    subnet: { id: '${vnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${s}'
        properties: {
          privateLinkServiceId: stg.id
          groupIds: [ s ]
        }
      }
    ]
  }
}]

// Register the PE private IPs into the matching DNS zone
resource peDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (s, i) in services: {
  parent: privateEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config-${s}'
        properties: { privateDnsZoneId: dnsZones[i].id }
      }
    ]
  }
}]

output vnetName string = vnet.name
output appSubnetName string = appSubnetName
