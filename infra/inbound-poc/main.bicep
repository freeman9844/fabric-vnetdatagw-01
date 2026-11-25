targetScope = 'subscription'

@description('Unique lowercase alphanumeric identifier for the isolated PoC run.')
@minLength(6)
@maxLength(16)
param runId string

@secure()
@description('Sign-in name of the PoC Fabric capacity administrator.')
param capacityAdmin string

@description('Public key for the temporary probe VM.')
param sshPublicKey string

var location = 'westus3'
var tags = {
  Control: 'Yes'
  Purpose: 'fabric-inbound-pe-poc'
  PocRun: runId
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-fabric-inbound-pe-poc'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'fabric-inbound-${runId}'
  scope: group
  params: {
    location: location
    runId: runId
    tags: tags
    capacityAdmin: capacityAdmin
    sshPublicKey: sshPublicKey
  }
}

output capacityName string = resources.outputs.capacityName
output bastionName string = resources.outputs.bastionName
output vmId string = resources.outputs.vmId
