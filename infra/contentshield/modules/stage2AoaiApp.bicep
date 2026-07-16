// stage2AoaiApp.bicep — Stage-2 "AOAI-CPU" Container App.
//
// The cheap, GPU-free Stage-2 variant. It runs the same /health + /classify
// contract as the GPU (vLLM) Stage-2, but delegates classification to an Azure
// OpenAI gpt-4o deployment instead of an in-container model. Built from
// services/stage2/Dockerfile.aoai-cpu (STAGE2_BACKEND=azure_openai).
//
// Runs on the Consumption workload profile (no GPU quota required) with a small
// CPU/memory footprint. Internal ingress only — the orchestrator reaches it via
// http://<name>/classify inside the CAE.
//
// Auth to Azure OpenAI:
//   * If azureOpenAiApiKey is supplied, it is stored as a secret and passed as
//     AZURE_OPENAI_API_KEY (key auth).
//   * Otherwise the wrapper falls back to DefaultAzureCredential (this app's
//     system-assigned managed identity). The caller must then grant that MI the
//     "Cognitive Services OpenAI User" role on the target Azure OpenAI /
//     AIServices account. For a cross-resource-group target that grant is done
//     out-of-band by deploy.ps1 (see -AzureOpenAiResourceId).

param location string
param tags object
param caeName string
param acrLoginServer string
param appInsightsConnectionString string
param natGatewayPublicIp string

@description('Static IP of the CAE — added to ingress allowlist so the orchestrator can reach this app via internal ingress.')
param caeStaticIp string = ''

@description('Optional extra IP CIDR ranges to allow on this app ingress.')
param extraAllowedIps array = []

@description('Container App name (e.g., ca-cs-stage2-aoai).')
param name string

@description('Full image reference: <acrLoginServer>/contentshield-stage2:<aoai-cpu-tag>.')
param image string

param targetPort int = 8080

@description('Azure OpenAI endpoint, e.g. https://myfoundry.cognitiveservices.azure.com/. Required.')
param azureOpenAiEndpoint string

@description('Azure OpenAI deployment (model) name, e.g. gpt-4o.')
param azureOpenAiDeployment string = 'gpt-4o'

@description('Azure OpenAI API version.')
param azureOpenAiApiVersion string = '2024-10-21'

@description('Optional Azure OpenAI API key. Leave empty to use this app managed identity (DefaultAzureCredential).')
@secure()
param azureOpenAiApiKey string = ''

@description('Minimum replicas. Default 1 keeps the wrapper warm (it is cheap CPU-only).')
@minValue(0)
@maxValue(10)
param minReplicas int = 1

@description('Maximum replicas.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

@description('CPU cores for the wrapper (Consumption profile). The wrapper is a thin proxy to Azure OpenAI.')
param cpuCores string = '1.0'

@description('Memory for the wrapper.')
param memory string = '2Gi'

@description('Free-form additional env merged after the AOAI env. Use for per-deploy overrides (e.g. AZURE_OPENAI_TIMEOUT_S).')
param extraEnv array = []

@description('Revision suffix derived from the image string; revisions only roll when the image changes.')
var revisionSuffix = 'r${take(uniqueString(image), 8)}'

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: caeName
}

var apiKeyEnv = empty(azureOpenAiApiKey) ? [] : [
  {
    name: 'AZURE_OPENAI_API_KEY'
    secretRef: 'aoai-api-key'
  }
]

var aoaiEnv = [
  {
    name: 'STAGE2_BACKEND'
    value: 'azure_openai'
  }
  {
    name: 'AZURE_OPENAI_ENDPOINT'
    value: azureOpenAiEndpoint
  }
  {
    name: 'AZURE_OPENAI_DEPLOYMENT'
    value: azureOpenAiDeployment
  }
  {
    name: 'AZURE_OPENAI_API_VERSION'
    value: azureOpenAiApiVersion
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
]

var fullEnv = concat(apiKeyEnv, aoaiEnv, extraEnv)

var secrets = empty(azureOpenAiApiKey) ? [] : [
  {
    name: 'aoai-api-key'
    value: azureOpenAiApiKey
  }
]

var baseIpRules = [
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
var ipRules = concat(baseIpRules, caeIpRule, extraIpRules)

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: name
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
            cpu: json(cpuCores)
            memory: memory
          }
          env: fullEnv
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 15
              periodSeconds: 20
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: targetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 5
              successThreshold: 1
              failureThreshold: 6
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/health'
                port: targetPort
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 5
              timeoutSeconds: 3
              successThreshold: 1
              failureThreshold: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        cooldownPeriod: 300
        pollingInterval: 30
        rules: [
          {
            name: 'http-scaler'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
    }
  }
}

output name string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output principalId string = app.identity.principalId
