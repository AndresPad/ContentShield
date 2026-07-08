// stage2App.bicep — one Stage-2 GPU Container App, parameterised per variant.
//
// Used by main.bicep when stage2Variants[] is non-empty. Each entry in that
// array becomes one instance of this module, so we can run baked-local, baked,
// and cache-disabled side-by-side in the same CAE for A/B/C cold-start +
// classify-latency testing.
//
// Design notes (important — see A1-baked-internals finding):
//   * The vendor images (gemma4-31b-model-baked-local, -baked, -cache-disabled)
//     already self-configure MODEL_NAME, HF_HOME, PROMPT_PATH, REASON_PROMPT_PATH,
//     and PYTHONPATH in their Dockerfile ENV. baked-local also sets
//     HF_HUB_OFFLINE=true / TRANSFORMERS_OFFLINE=true.
//   * Therefore this module DOES NOT set those env vars. It only injects:
//       - tuneables   : MAX_MODEL_LEN, GPU_MEMORY_UTILIZATION, EXTRA_ENGINE_ARGS,
//                       LANGUAGE_MODEL_ONLY, ENABLE_THINKING, CACHE_ENABLED
//       - observability: APPLICATIONINSIGHTS_CONNECTION_STRING
//       - optional    : HF_TOKEN (only when hfToken is non-empty — typically
//                       only the cache-disabled variant needs it)
//       - per-variant : caller-supplied extraEnv[] (free-form overrides)
//   * Setting MODEL_NAME or HF_HOME via extraEnv would clobber the image
//     defaults. baked-local would then break (offline mode forbids fallback).
//     Reviewer: validate any extraEnv entry that sets MODEL_NAME / HF_HOME.

param location string
param tags object
param caeName string
param acrLoginServer string
param appInsightsConnectionString string
param natGatewayPublicIp string
@description('Static IP of the CAE — added to ingress allowlist so the orchestrator can reach this variant via internal ingress.')
param caeStaticIp string = ''
@description('Optional extra IP CIDR ranges to allow on this variant ingress.')
param extraAllowedIps array = []

@description('Container App name (e.g., ca-contentshield-stage2-baked-local).')
param name string
@description('Full image reference: <acrLoginServer>/contentshield-stage2@sha256:... or :<tag>.')
param image string
@description('GPU workload profile to schedule on (e.g., NC24-A100).')
param gpuWorkloadProfileName string
param targetPort int = 8080

@description('Mount the CAE-registered hfcache NFS share into this variant. Only set true for the cache-disabled variant (or when explicitly testing NFS-warm scenarios). Baked variants must NOT mount the share — they would shadow the in-image weights or break offline mode.')
param mountNfs bool = false
@description('Storage account name (used to compute /mount/<sa>/<share>).')
param storageAccountName string = ''
@description('NFS share name (CAE storage definition name).')
param hfCacheShareName string = 'hfcache'

@description('Minimum replicas. Default 0 so the variant idles at zero cost between test runs; the test harness scales it to 1 to measure cold start.')
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

@description('Optional Hugging Face token. Only inject for variants that need to download (cache-disabled).')
@secure()
param hfToken string = ''

@description('vLLM batches internally so per-replica concurrency can be high. Use 30 in-flight requests as the trigger to add a second replica — well above one replica\'s comfortable throughput but below the point where p95 latency degrades.')
param scalerConcurrentRequests string = '30'

@description('ACA scaler cooldown (seconds) — how long a scaled-up replica stays before scale-down is allowed. 600s = 10 min keeps GPU node warm between bursts.')
param scalerCooldownSec int = 600

@description('Free-form additional env to merge after the tuneables. Use for per-variant overrides only; do NOT set MODEL_NAME or HF_HOME here unless you have a specific reason — see file header.')
param extraEnv array = []

@description('Revision suffix is derived from the image string; revisions only roll when the image changes.')
var revisionSuffix = 'r${take(uniqueString(image), 8)}'

@description('Computed mount path for the optional NFS share.')
var nfsMountPath = empty(storageAccountName) ? '/mnt/hfcache' : '/mount/${storageAccountName}/${hfCacheShareName}'

resource cae 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: caeName
}

// Tuneables every variant gets. Image defaults for MODEL_NAME / HF_HOME /
// PROMPT_PATH etc. are intentionally NOT included — the image ships them.
var tuneableEnv = [
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
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
]

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

var volumeMounts = mountNfs ? [
  {
    mountPath: nfsMountPath
    volumeName: hfCacheShareName
  }
] : []

var volumes = mountNfs ? [
  {
    name: hfCacheShareName
    storageName: hfCacheShareName
    storageType: 'NfsAzureFile'
  }
] : []

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: name
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
            // Consume the whole node per replica so the single GPU is guaranteed
            // attached. Fractional sizes (e.g. 6/12Gi) let ACA pack multiple
            // replicas onto one node and only the first gets the GPU; the others
            // boot fine but fail at vLLM init with "No CUDA GPUs are available".
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
              failureThreshold: 180
            }
          ]
          volumeMounts: volumeMounts
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        cooldownPeriod: scalerCooldownSec
        pollingInterval: 15
        rules: [
          {
            // vLLM batches internally; one warm A100 replica can absorb a real
            // burst before ACA needs a second. The previous value (1) caused
            // scaler flap on every probe and forced a 12-min cold start on
            // every burst. Tune up/down with measured p95.
            name: 'http-scaler'
            http: {
              metadata: {
                concurrentRequests: scalerConcurrentRequests
              }
            }
          }
        ]
      }
      volumes: volumes
      terminationGracePeriodSeconds: 60
    }
  }
}

output name string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output principalId string = app.identity.principalId
