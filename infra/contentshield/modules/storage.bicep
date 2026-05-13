// Premium FileStorage account with an NFS file share named 'hfcache'.
// Mirrors ratioaivllmnfs in rg-ratio-ai-dev:
//   - kind = FileStorage, SKU = Premium_LRS
//   - allowSharedKeyAccess = false, defaultToOAuthAuthentication = true
//   - enableHttpsTrafficOnly = false (required for NFS 4.1)
//   - largeFileSharesState = Enabled
//   - NFS file share 'hfcache' (default 500 GiB, NoRootSquash)
//   - Network: default Deny, VNet rules for the CAE + GPU subnets
//
// Sample mount (from inside a VM with line-of-sight to the storage account):
//   sudo mkdir -p /mount/<accountName>/hfcache
//   sudo mount -t aznfs <accountName>.file.core.windows.net:/<accountName>/hfcache \
//       /mount/<accountName>/hfcache -o vers=4,minorversion=1,sec=sys,nconnect=4

param location string
param tags object

@minLength(3)
@maxLength(24)
@description('Globally-unique storage account name (3-24, lowercase alphanumeric).')
param name string

@description('File share quota in GiB (Premium file shares: min 100).')
@minValue(100)
@maxValue(102400)
param shareQuotaGiB int = 500

@description('Subnet resource IDs that are allowed to reach the storage account (Microsoft.Storage service endpoint must be enabled on each).')
param allowedSubnetIds array

@description('NFS share name.')
param shareName string = 'hfcache'

@description('Root-squash policy on the NFS share.')
@allowed([
  'NoRootSquash'
  'RootSquash'
  'AllSquash'
])
param rootSquash string = 'NoRootSquash'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: false
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    largeFileSharesState: 'Enabled'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [for subnetId in allowedSubnetIds: {
        id: subnetId
        action: 'Allow'
      }]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    protocolSettings: {
      smb: {
        multichannel: {
          enabled: true
        }
      }
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    accessTier: 'Premium'
    enabledProtocols: 'NFS'
    rootSquash: rootSquash
    shareQuota: shareQuotaGiB
  }
}

output id string = sa.id
output name string = sa.name
output fileEndpointHost string = '${sa.name}.file.core.windows.net'
// Path used by the CAE NFS storage definition: /<account>/<share>
output nfsSharePath string = '/${sa.name}/${shareName}'
output shareName string = shareName
