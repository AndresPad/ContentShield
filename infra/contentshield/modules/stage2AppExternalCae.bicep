// stage2AppExternalCae.bicep — one Stage-2 GPU Container App that targets an
// EXISTING Container Apps Environment in a DIFFERENT resource group (and
// possibly a different region from the rest of this RG's resources).
//
// Why a separate module from modules/stage2App.bicep?
//   stage2App.bicep references the CAE via `Microsoft.App/managedEnvironments
//   existing = { name: caeName }`, which only resolves inside the deployment
//   target RG. For the eastus GPU-quota smoke test we need to pin a Container
//   App in rg-contentshield to a CAE that lives in rg-ratio-ai-dev — so this
//   module accepts the full `caeResourceId` and uses it directly as
//   `properties.environmentId`. No scope-crossing `existing` lookup needed.
//
// Image-pull identity:
//   Uses `identity: 'system-environment'`, i.e. the *CAE*'s system-assigned
//   managed identity. That identity must already have AcrPull on the source
//   ACR (e.g. ratioai.azurecr.io). This template does NOT grant that role —
//   it lives outside the rg-contentshield blast radius. See the deploy script
//   for guidance.

param location string
param tags object = {}

@description('Full resource id of the existing Container Apps Environment (any RG, same region as `location`).')
param caeResourceId string

@description('Login server of the source ACR (e.g. ratioai.azurecr.io).')
param acrLoginServer string

@description('Application Insights connection string for telemetry. Optional — leave blank to skip.')
param appInsightsConnectionString string = ''

@description('NAT gateway public IP to allow on ingress. Optional.')
param natGatewayPublicIp string = ''

@description('Static IP of the CAE — added to ingress allowlist so an in-env caller can reach this app via internal ingress. Optional.')
param caeStaticIp string = ''

@description('Optional extra IP CIDR ranges to allow on ingress.')
param extraAllowedIps array = []

@description('Container App name.')
param name string

@description('Full image reference, e.g. ratioai.azurecr.io/contentshield-stage2:1.0.1.')
param image string

@description('GPU workload profile name configured on the target CAE (e.g. NC24-A100).')
param gpuWorkloadProfileName string

param targetPort int = 8080

@description('Minimum replicas. 0 lets the app idle at zero cost; 1 keeps a warm GPU pinned for fast classify p50.')
@minValue(0)
@maxValue(5)
param minReplicas int = 0

@description('Maximum replicas.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 1

@description('Tuneable: vLLM --max-model-len. 20000 is the validated single-A100 ceiling for gemma-4-31b-it.')
param maxModelLen string = '20000'

@description('Tuneable: vLLM --gpu-memory-utilization. 0.9 is the validated single-A100 setting.')
param gpuMemoryUtilization string = '0.9'

@description('Tuneable: extra engine args, e.g. "--enable-prefix-caching".')
param extraEngineArgs string = '--enable-prefix-caching'

@description('start-vllm.sh flag → vLLM --language-model-only.')
param languageModelOnly string = 'true'

@description('start-vllm.sh flag → controls Gemma reasoning template. Keep false for label-only guided-choice path.')
param enableThinking string = 'false'

@description('Wrapper-side reason-cache toggle.')
param cacheEnabled string = 'true'

@description('Optional Hugging Face token. Required only by the cache-disabled variant when no NFS share is mounted.')
@secure()
param hfToken string = ''

@description('ACA HTTP scaler concurrent-requests trigger.')
param scalerConcurrentRequests string = '30'

@description('ACA scaler cooldown (seconds).')
param scalerCooldownSec int = 600

@description('Free-form additional env to merge after the tuneables. Avoid setting MODEL_NAME / HF_HOME unless you know what you are doing — see modules/stage2App.bicep header for context.')
param extraEnv array = []

var revisionSuffix = 'r${take(uniqueString(image), 8)}'

var aiEnv = empty(appInsightsConnectionString) ? [] : [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
]

var tuneableEnv = concat([
  {
    name: 'MAX_MODEL_LEN'
    value: maxModelLen
  }
  {
    name: 'GPU_MEMORY_UTILIZATION'
    value: gpuMemoryUtilization
  }
  {
    name: 'LANGUAGE_MODEL_ONLY'
    value: languageModelOnly
  }
  {
    name: 'EXTRA_ENGINE_ARGS'
    value: extraEngineArgs
  }
  {
    name: 'ENABLE_THINKING'
    value: enableThinking
  }
  {
    name: 'CACHE_ENABLED'
    value: cacheEnabled
  }
], aiEnv)

var hfTokenEnv = empty(hfToken) ? [] : [
  {
    name: 'HF_TOKEN'
    secretRef: 'hf-token'
  }
]

var fullEnv = concat(hfTokenEnv, tuneableEnv, extraEnv)

var secrets = empty(hfToken) ? [] : [
  {
    name: 'hf-token'
    value: hfToken
  }
]

var natIpRule = empty(natGatewayPublicIp) ? [] : [
  {
    name: 'AllowAPIMNatGateway'
    action: 'Allow'
    ipAddressRange: '${natGatewayPublicIp}/32'
  }
]
var caeIpRule = empty(caeStaticIp) ? [] : [
  {
    name: 'AllowACAEnvStatic'
    description: 'Allow same ACA environment static IP'
    action: 'Allow'
    ipAddressRange: '${caeStaticIp}/32'
  }
]
var extraIpRules = [for (ip, i) in extraAllowedIps: {
  name: 'AllowExtra${i}'
  action: 'Allow'
  ipAddressRange: ip
}]
var ipRules = concat(natIpRule, caeIpRule, extraIpRules)

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: caeResourceId
    workloadProfileName: gpuWorkloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: targetPort
        transport: 'Auto'
        allowInsecure: false
        ipSecurityRestrictions: ipRules
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
      secrets: secrets
      maxInactiveRevisions: 100
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          name: name
          image: image
          resources: {
            // NC24-A100 node = 24 vCPU / 220 GiB / 1×A100 80GB.
            // Consume the whole node per replica so the single GPU is guaranteed attached.
            cpu: json('24.0')
            memory: '220Gi'
          }
          env: fullEnv
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: targetPort
              }
              periodSeconds: 10
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: targetPort
              }
              periodSeconds: 5
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 48
            }
            {
              type: 'Startup'
              tcpSocket: {
                port: targetPort
              }
              initialDelaySeconds: 5
              periodSeconds: 5
              timeoutSeconds: 3
              successThreshold: 1
              failureThreshold: 240
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        cooldownPeriod: scalerCooldownSec
        pollingInterval: 15
        rules: [
          {
            name: 'http-scaler'
            http: {
              metadata: {
                concurrentRequests: scalerConcurrentRequests
              }
            }
          }
        ]
      }
      terminationGracePeriodSeconds: 60
    }
  }
}

output name string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output principalId string = app.identity.principalId
