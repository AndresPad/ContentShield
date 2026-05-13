// ca-ratio-contentshield (Consumption profile, external ingress, IP-allowlist for NAT GW)
// ca-contentshield-stage2 (GPU profile, internal ingress, optional NFS mount)
//
// Both apps use system-assigned managed identity and pull images from ACR using
// the environment-level managed identity (registries: { identity: 'system-environment' }).
// The CAE's system MI must be granted AcrPull on the ACR — done by acrPullForCae role assignment.

param location string
param tags object
param caeName string
param acrLoginServer string
param acrResourceId string
param appInsightsConnectionString string
param contentSafetyEndpoint string
param ratioAiDevClientId string

// Main app
param appName string
param appImage string
param appTargetPort int
param natGatewayPublicIp string
@description('Static IP of the Container Apps Environment (used as a stage-2 ingress allowlist entry so the app can reach itself / sibling apps via internal ingress).')
param caeStaticIp string = ''
@description('Optional list of extra IP CIDR ranges to allow on stage-2 ingress.')
param extraStage2AllowedIps array = []
@description('Model name the SLM serves — exposed to the main app via SLM_MODEL.')
param slmModel string = 'google/gemma-4-31b-it'
@description('Feature flag CONTENTSHIELD_V1_ML_DISABLED on the main app. Set to "0" to re-enable the legacy ML path.')
param contentshieldV1MlDisabled string = '1'
@description('Optional cache-buster injected as REDEPLOY_TS env var. Bump to force a new container app revision even when no other property changes.')
param redeployTimestamp string = ''

// Stage 2 (GPU)
param deployStage2 bool
param stage2AppName string
param stage2Image string
param stage2TargetPort int
param gpuWorkloadProfileName string
@secure()
param hfToken string = ''
param nfsStorageMounted bool
@description('Storage account name. Used to compute the mount path /mount/<accountName>/<share>.')
param storageAccountName string = ''
@description('NFS share name used as the mount sub-path (also the volume name in CAE storage).')
param hfCacheShareName string = 'hfcache'

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: caeName
}

// Grant the CAE's system-assigned MI AcrPull on the ACR so apps can use
// registries: { identity: 'system-environment' } to pull images without secrets.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
resource acrPullForCae 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResourceId, caeName, acrPullRoleId)
  scope: resourceGroup()
  properties: {
    principalId: cae.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: appTargetPort
        transport: 'Auto'
        allowInsecure: false
        clientCertificateMode: 'Ignore'
        ipSecurityRestrictions: [
          {
            name: 'AllowAPIMNatGateway'
            action: 'Allow'
            ipAddressRange: '${natGatewayPublicIp}/32'
          }
        ]
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: 'system-environment'
        }
      ]
      maxInactiveRevisions: 100
    }
    template: {
      containers: [
        {
          name: appName
          image: appImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
            ephemeralStorage: '2Gi'
          }
          env: concat([
            {
              name: 'CONTENT_SAFETY_ENDPOINT'
              value: contentSafetyEndpoint
            }
            {
              name: 'CONTENT_SAFETY_API_VERSION'
              value: '2024-09-01'
            }
            {
              name: 'SLM_ENDPOINT'
              value: 'http://${stage2AppName}'
            }
            {
              name: 'SLM_PATH'
              value: '/classify'
            }
            {
              name: 'SLM_MODEL'
              value: slmModel
            }
            {
              name: 'SLM_TIMEOUT_SECONDS'
              value: '60'
            }
            {
              name: 'CONTENTSHIELD_V1_ML_DISABLED'
              value: contentshieldV1MlDisabled
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsightsConnectionString
            }
            {
              name: 'RATIO_AI_DEV_CLIENT_ID'
              value: ratioAiDevClientId
            }
          ], empty(redeployTimestamp) ? [] : [
            {
              name: 'REDEPLOY_TS'
              value: redeployTimestamp
            }
          ])
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: appTargetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 30
              periodSeconds: 20
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: appTargetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/health'
                port: appTargetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
        cooldownPeriod: 300
        pollingInterval: 30
        rules: [
          {
            name: 'http-scaler'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPullForCae
  ]
}

// ── Stage 2 (GPU) ───────────────────────────────────────────────────────────

var stage2Secrets = empty(hfToken) ? [] : [
  {
    name: 'hf-token'
    value: hfToken
  }
]

var hfCacheMountPath = empty(storageAccountName) ? '/mnt/hfcache' : '/mount/${storageAccountName}/${hfCacheShareName}'

var stage2EnvBase = concat([
  {
    name: 'MODEL_NAME'
    value: slmModel
  }
  {
    name: 'MAX_MODEL_LEN'
    value: '20000'
  }
  {
    name: 'GPU_MEMORY_UTILIZATION'
    value: '0.9'
  }
  {
    name: 'LANGUAGE_MODEL_ONLY'
    value: 'true'
  }
  {
    name: 'EXTRA_ENGINE_ARGS'
    value: '--enable-prefix-caching'
  }
  {
    name: 'HF_HOME'
    value: hfCacheMountPath
  }
  {
    name: 'ENABLE_THINKING'
    value: 'false'
  }
  {
    name: 'CACHE_ENABLED'
    value: 'true'
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
], empty(redeployTimestamp) ? [] : [
  {
    name: 'REDEPLOY_TS'
    value: redeployTimestamp
  }
])

var stage2EnvWithHf = empty(hfToken) ? stage2EnvBase : concat([
  {
    name: 'HF_TOKEN'
    secretRef: 'hf-token'
  }
], stage2EnvBase)

var stage2VolumeMounts = nfsStorageMounted ? [
  {
    mountPath: hfCacheMountPath
    volumeName: 'hfcache'
  }
] : []

var stage2Volumes = nfsStorageMounted ? [
  {
    name: 'hfcache'
    storageName: 'hfcache'
    storageType: 'NfsAzureFile'
  }
] : []

var stage2BaseIpRules = [
  {
    name: 'AllowAPIMNatGateway'
    action: 'Allow'
    ipAddressRange: '${natGatewayPublicIp}/32'
  }
]
var stage2CaeRule = empty(caeStaticIp) ? [] : [
  {
    name: 'AllowACAEnvStatic'
    description: 'Allow same ACA environment static IP'
    action: 'Allow'
    ipAddressRange: '${caeStaticIp}/32'
  }
]
var stage2ExtraRules = [for (ip, i) in extraStage2AllowedIps: {
  name: 'AllowExtra${i}'
  action: 'Allow'
  ipAddressRange: ip
}]
var stage2IpRules = concat(stage2BaseIpRules, stage2CaeRule, stage2ExtraRules)

resource stage2 'Microsoft.App/containerApps@2024-10-02-preview' = if (deployStage2) {
  name: stage2AppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: cae.id
    workloadProfileName: gpuWorkloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: stage2TargetPort
        transport: 'Auto'
        allowInsecure: false
        ipSecurityRestrictions: stage2IpRules
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: 'system-environment'
        }
      ]
      secrets: stage2Secrets
      maxInactiveRevisions: 100
    }
    template: {
      containers: [
        {
          name: stage2AppName
          image: stage2Image
          resources: {
            cpu: json('6.0')
            memory: '12Gi'
          }
          env: stage2EnvWithHf
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: stage2TargetPort
              }
              periodSeconds: 10
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: stage2TargetPort
              }
              periodSeconds: 5
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 48
            }
            {
              type: 'Startup'
              tcpSocket: {
                port: stage2TargetPort
              }
              initialDelaySeconds: 1
              periodSeconds: 1
              timeoutSeconds: 3
              successThreshold: 1
              failureThreshold: 240
            }
          ]
          volumeMounts: stage2VolumeMounts
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        cooldownPeriod: 300
        pollingInterval: 30
        rules: [
          {
            name: 'http-scaler'
            http: {
              metadata: {
                concurrentRequests: '1'
              }
            }
          }
        ]
      }
      volumes: stage2Volumes
    }
  }
  dependsOn: [
    acrPullForCae
  ]
}

output appFqdn string = app.properties.configuration.ingress.fqdn
output appPrincipalId string = app.identity.principalId
output stage2Fqdn string = deployStage2 ? stage2!.properties.configuration.ingress.fqdn : ''
output stage2PrincipalId string = deployStage2 ? stage2!.identity.principalId : ''
