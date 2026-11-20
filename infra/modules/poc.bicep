@description('Lowercase alphanumeric suffix for the resources in the PoC.')
param nameSuffix string

@description('Region of the PoC resources.')
param location string

@description('Tags required on the PoC resources.')
param tags object

var subnetName = 'snet-fabric-gateway'
var publicIpName = 'pip-fabric-nat-${nameSuffix}'
var natName = 'ng-fabric-nat-${nameSuffix}'
var appName = 'app-fabric-nat-${nameSuffix}-${uniqueString(resourceGroup().id)}'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nat 'Microsoft.Network/natGateways@2024-07-01' = {
  name: natName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-fabric-nat-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.30.0/24'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.20.30.0/27'
          defaultOutboundAccess: false
          natGateway: {
            id: nat.id
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
    ]
  }
}

resource appPlan 'Microsoft.Web/serverfarms@2025-03-01' = {
  // checkov:skip=CKV_AZURE_225:Short-lived single-instance B1 PoC; zonal HA is out of scope.
  name: 'asp-fabric-nat-${nameSuffix}'
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
  // checkov:skip=CKV_AZURE_222:Public HTTPS is the test target; only the NAT IPv4 is allowed.
  // checkov:skip=CKV_AZURE_17:Anonymous Fabric REST must exercise the IP allowlist without client certificates.
  // checkov:skip=CKV_AZURE_16:The synthetic API uses an IP allowlist; SCM deployment still requires Entra ID.
  // checkov:skip=CKV_AZURE_71:The app has no dependencies, downstream calls, or secrets.
  // checkov:skip=CKV_AZURE_212:Failover is out of scope for the short-lived single-instance PoC.
  // checkov:skip=CKV_AZURE_213:The single-instance PoC uses explicit end-to-end Fabric probes, not health-based failover.
  name: appName
  location: location
  tags: tags
  kind: 'app,linux'
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: 'NODE|24-lts'
      appCommandLine: 'node server.mjs'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      ftpsState: 'Disabled'
      remoteDebuggingEnabled: false
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: [
        {
          name: 'Allow-Fabric-NAT'
          priority: 100
          action: 'Allow'
          ipAddress: '${publicIp.properties.ipAddress}/32'
        }
        {
          name: 'Audit-Deny-Other-IPv4'
          priority: 200
          action: 'Deny'
          ipAddress: '0.0.0.0/0'
        }
      ]
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictions: []
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

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: 'log-fabric-nat-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json('0.1')
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-client-ip'
  scope: app
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceIPSecAuditLogs'
        enabled: true
      }
    ]
  }
}

output subnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetName)
output natGatewayId string = nat.id
output publicIpResourceId string = publicIp.id
output mockAppId string = app.id
output mockHostname string = app.properties.defaultHostName
output logWorkspaceId string = workspace.id
