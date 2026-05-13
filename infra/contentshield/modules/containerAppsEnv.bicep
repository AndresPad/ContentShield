// Container Apps Environment — workload profiles (Consumption + optional GPU),
// VNet integration, Log Analytics + App Insights wiring.
// Optionally registers an NFS Azure Files storage mount named 'hfcache'.

param location string
param tags object
param name string
param infrastructureSubnetId string
param logAnalyticsCustomerId string
@secure()
param logAnalyticsSharedKey string
param appInsightsConnectionString string

@description('GPU workload profile name. Empty string skips the GPU profile.')
param gpuWorkloadProfileName string = 'NC24-A100'

@description('GPU workload profile type. e.g. Consumption-GPU-NC24-A100.')
param gpuWorkloadProfileType string = 'Consumption-GPU-NC24-A100'

@description('NFS Azure Files server (empty to skip).')
param nfsServer string = ''

@description('NFS share name (empty to skip).')
param nfsShareName string = ''

var baseProfile = {
  name: 'Consumption'
  workloadProfileType: 'Consumption'
}

var gpuProfile = {
  name: gpuWorkloadProfileName
  workloadProfileType: gpuWorkloadProfileType
}

var workloadProfiles = empty(gpuWorkloadProfileName) ? [
  baseProfile
] : [
  baseProfile
  gpuProfile
]

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
        dynamicJsonColumns: true
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    }
    workloadProfiles: workloadProfiles
    openTelemetryConfiguration: {
      logsConfiguration: {
        destinations: [
          'appInsights'
        ]
      }
      tracesConfiguration: {
        destinations: [
          'appInsights'
        ]
        includeDapr: false
      }
    }
    appInsightsConfiguration: {
      connectionString: appInsightsConnectionString
    }
    peerAuthentication: {
      mtls: {
        enabled: false
      }
    }
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
  }
}

resource hfCacheStorage 'Microsoft.App/managedEnvironments/storages@2024-10-02-preview' = if (!empty(nfsServer) && !empty(nfsShareName)) {
  parent: cae
  name: 'hfcache'
  properties: {
    nfsAzureFile: {
      server: nfsServer
      shareName: nfsShareName
      accessMode: 'ReadWrite'
    }
  }
}

output id string = cae.id
output name string = cae.name
output defaultDomain string = cae.properties.defaultDomain
output staticIp string = cae.properties.staticIp
output principalId string = cae.identity.principalId
