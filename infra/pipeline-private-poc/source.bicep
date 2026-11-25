@description('Region of the disposable environment.')
param location string

@description('Unique test run identifier.')
param runId string

@description('Cleanup ownership tags.')
param tags object

@description('VNet created by the base module for this run.')
param vnetName string

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: vnetName
}

resource gatewayRoutes 'Microsoft.Network/routeTables@2024-07-01' = {
  name: 'rt-fabric-gateway'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: 'snet-fabric-gateway'
  properties: {
    addressPrefix: '10.91.0.192/27'
    defaultOutboundAccess: false
    routeTable: {
      id: gatewayRoutes.id
    }
    delegations: [
      {
        name: 'fabric'
        properties: {
          serviceName: 'Microsoft.PowerPlatform/vnetaccesslinks'
        }
      }
    ]
    serviceEndpoints: [
      {
        service: 'Microsoft.AzureActiveDirectory'
      }
      {
        service: 'Microsoft.Storage'
      }
    ]
  }
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: 'app-endpoint'
  properties: {
    addressPrefix: '10.91.0.160/27'
    defaultOutboundAccess: false
    privateEndpointNetworkPolicies: 'RouteTableEnabled'
  }
  dependsOn: [gatewaySubnet]
}

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  // checkov:skip=CKV_AZURE_225:One disposable B1 instance; no production availability objective.
  name: 'asp-fabric-pipeline-${runId}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2025-03-01' = {
  // checkov:skip=CKV_AZURE_17:Fabric's private synthetic REST source does not use a client certificate.
  // checkov:skip=CKV_AZURE_16:The app is private-only and returns only synthetic fixtures.
  // checkov:skip=CKV_AZURE_71:The mock has no downstream calls or secrets to access.
  // checkov:skip=CKV_AZURE_212:Failover is out of scope for the short-lived single instance.
  name: 'app-fabric-pipeline-${runId}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'NODE|24-lts'
      appCommandLine: 'node server.mjs'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      ftpsState: 'Disabled'
      remoteDebuggingEnabled: false
      alwaysOn: true
      httpLoggingEnabled: true
      healthCheckPath: '/'
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: true
    }
  }
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

resource appEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: 'pe-app-service'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: appSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: app.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource dns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}

resource networkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dns
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
  parent: appEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'app-service'
        properties: {
          privateDnsZoneId: dns.id
        }
      }
    ]
  }
}

output gatewaySubnetId string = gatewaySubnet.id
output gatewayRouteTableId string = gatewayRoutes.id
output appId string = app.id
output appHost string = app.properties.defaultHostName
output appEndpointId string = appEndpoint.id
