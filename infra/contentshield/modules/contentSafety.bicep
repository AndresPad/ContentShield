// Azure AI Content Safety account.
param location string
param tags object
param name string
param sku string = 'S0'

resource cs 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'ContentSafety'
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

output id string = cs.id
output name string = cs.name
output endpoint string = cs.properties.endpoint
output principalId string = cs.identity.principalId
