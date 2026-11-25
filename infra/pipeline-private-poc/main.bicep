targetScope = 'subscription'

@description('Unique lowercase alphanumeric identifier for this disposable run.')
@minLength(6)
@maxLength(16)
param runId string

@secure()
@description('Sign-in name of the administrator of the new F2 capacity.')
param capacityAdmin string

@description('SSH public key for the private administration VM.')
param sshPublicKey string

var location = 'westus3'
var vnetName = 'vnet-fabric-inbound-poc'
var tags = {
  Control: 'Yes'
  Purpose: 'fabric-pipeline-pe-poc'
  PocRun: runId
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-fabric-pipeline-pe-poc'
  location: location
  tags: tags
}

module base '../inbound-poc/resources.bicep' = {
  name: 'pipeline-base-${runId}'
  scope: group
  params: {
    location: location
    runId: runId
    tags: tags
    capacityAdmin: capacityAdmin
    sshPublicKey: sshPublicKey
    endpointNetworkPolicies: 'RouteTableEnabled'
  }
}

module source 'source.bicep' = {
  name: 'pipeline-source-${runId}'
  scope: group
  params: {
    location: location
    runId: runId
    tags: tags
    vnetName: vnetName
  }
  dependsOn: [base]
}

output capacityName string = base.outputs.capacityName
output bastionName string = base.outputs.bastionName
output vmId string = base.outputs.vmId
output vnetName string = vnetName
output gatewaySubnetId string = source.outputs.gatewaySubnetId
output gatewayRouteTableId string = source.outputs.gatewayRouteTableId
output appId string = source.outputs.appId
output appHost string = source.outputs.appHost
output appEndpointId string = source.outputs.appEndpointId
