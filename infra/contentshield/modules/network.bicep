// Public IP + NAT Gateway + 2 NSGs + VNet (3 subnets).
//
// Subnets:
//   - vllm-subnet      → Container Apps Environment (workload profile delegation)
//   - vllm-gpu-subnet  → reserved for GPU workloads, Microsoft.Storage service endpoint
//   - vllm-apim-subnet → APIM v2 (delegated to Microsoft.Web/serverFarms)
//
// All subnets attach the main NSG except the GPU subnet which uses its dedicated NSG.
// NAT GW attached to vllm-subnet and vllm-apim-subnet for stable outbound egress IP.

param location string
param tags object

param publicIpName string
param natGatewayName string
param nsgMainName string
param nsgGpuName string
param vnetName string

param vnetAddressPrefix string
param subnetCaePrefix string
param subnetGpuPrefix string
param subnetApimPrefix string

// Azure Core Security baseline NSG rules (NRMS) — required for compliance.
// These mirror the rules currently provisioned by Azure Core Security policy on the live RG.
var nrmsRules = [
  {
    name: 'NRMS-Rule-101'
    properties: {
      description: 'Created by Azure Core Security managed policy, placeholder you can delete'
      priority: 101
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'NRMS-Rule-103'
    properties: {
      description: 'Created by Azure Core Security managed policy'
      priority: 103
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'CorpNetPublic'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'NRMS-Rule-104'
    properties: {
      description: 'Created by Azure Core Security managed policy'
      priority: 104
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'CorpNetSaw'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'NRMS-Rule-105'
    properties: {
      description: 'DO NOT DELETE - Azure Core Security'
      priority: 105
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '1433'
        '1434'
        '3306'
        '4333'
        '5432'
        '6379'
        '7000'
        '7001'
        '7199'
        '9042'
        '9160'
        '9300'
        '16379'
        '26379'
        '27017'
      ]
    }
  }
  {
    name: 'NRMS-Rule-106'
    properties: {
      description: 'DO NOT DELETE - Azure Core Security'
      priority: 106
      direction: 'Inbound'
      access: 'Deny'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'NRMS-Rule-107'
    properties: {
      description: 'DO NOT DELETE - Azure Core Security'
      priority: 107
      direction: 'Inbound'
      access: 'Deny'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '23'
        '135'
        '445'
        '5985'
        '5986'
      ]
    }
  }
  {
    name: 'NRMS-Rule-108'
    properties: {
      description: 'DO NOT DELETE - Azure Core Security'
      priority: 108
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '13'
        '17'
        '19'
        '53'
        '69'
        '111'
        '123'
        '512'
        '514'
        '593'
        '873'
        '1900'
        '5353'
        '11211'
      ]
    }
  }
  {
    name: 'NRMS-Rule-109'
    properties: {
      description: 'DO NOT DELETE - Azure Core Security'
      priority: 109
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '119'
        '137'
        '138'
        '139'
        '161'
        '162'
        '389'
        '636'
        '2049'
        '2301'
        '2381'
        '3268'
        '5800'
        '5900'
      ]
    }
  }
]

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: pip.id
      }
    ]
  }
}

resource nsgMain 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgMainName
  location: location
  tags: tags
  properties: {
    securityRules: nrmsRules
  }
}

resource nsgGpu 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgGpuName
  location: location
  tags: tags
  properties: {
    securityRules: nrmsRules
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'vllm-subnet'
        properties: {
          addressPrefixes: [
            subnetCaePrefix
          ]
          networkSecurityGroup: {
            id: nsgMain.id
          }
          natGateway: {
            id: natGw.id
          }
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                'westus3'
                'eastus'
              ]
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'vllm-gpu-subnet'
        properties: {
          addressPrefixes: [
            subnetGpuPrefix
          ]
          networkSecurityGroup: {
            id: nsgGpu.id
          }
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                'westus3'
                'eastus'
              ]
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'vllm-apim-subnet'
        properties: {
          addressPrefixes: [
            subnetApimPrefix
          ]
          networkSecurityGroup: {
            id: nsgMain.id
          }
          natGateway: {
            id: natGw.id
          }
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output caeSubnetId string = '${vnet.id}/subnets/vllm-subnet'
output gpuSubnetId string = '${vnet.id}/subnets/vllm-gpu-subnet'
output apimSubnetId string = '${vnet.id}/subnets/vllm-apim-subnet'
output natGatewayId string = natGw.id
output natGatewayPublicIp string = pip.properties.ipAddress
output publicIpId string = pip.id
