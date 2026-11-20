targetScope = 'subscription'

@description('Name of the new resource group dedicated to this PoC.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Lowercase alphanumeric suffix for the resources in the PoC.')
@minLength(3)
@maxLength(20)
param nameSuffix string

@description('Region approved for this PoC.')
@allowed([
  'westus3'
])
param location string = 'westus3'

var tags = {
  Control: 'Yes'
  Purpose: 'fabric-nat-poc'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module poc 'modules/poc.bicep' = {
  name: 'fabric-nat-${nameSuffix}'
  scope: resourceGroup
  params: {
    nameSuffix: nameSuffix
    location: location
    tags: tags
  }
}

output subnetId string = poc.outputs.subnetId
output natGatewayId string = poc.outputs.natGatewayId
output publicIpResourceId string = poc.outputs.publicIpResourceId
output mockAppId string = poc.outputs.mockAppId
output mockHostname string = poc.outputs.mockHostname
output logWorkspaceId string = poc.outputs.logWorkspaceId
