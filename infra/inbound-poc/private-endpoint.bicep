param runId string
param workspaceId string
param tenantId string

var tags = {
  Control: 'Yes'
  Purpose: 'fabric-inbound-pe-poc'
  PocRun: runId
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: 'vnet-fabric-inbound-poc'
}

module workspaceLink 'workspace-link.json' = {
  name: 'fabric-workspace-link-${runId}'
  params: {
    workspaceId: workspaceId
    tenantId: tenantId
    tags: tags
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: 'pe-fabric-workspace'
  location: 'westus3'
  tags: tags
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/private-endpoint'
    }
    privateLinkServiceConnections: [
      {
        name: 'workspace'
        properties: {
          privateLinkServiceId: workspaceLink.outputs.linkId
          groupIds: ['workspace']
        }
      }
    ]
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.fabric.microsoft.com'
  location: 'global'
  tags: tags
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'poc-network'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'fabric'
        properties: {
          privateDnsZoneId: zone.id
        }
      }
    ]
  }
}

output endpointId string = endpoint.id
