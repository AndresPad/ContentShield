// =============================================================================
// ContentShield — eastus GPU smoke test
// =============================================================================
// Target scope:  resourceGroup (rg-contentshield)
// Target region: eastus (must match the existing CAE)
//
// Purpose:
//   Validate that ContentShield Stage-2 images run on an existing
//   Container Apps Environment with a Consumption-GPU-NC24-A100 workload
//   profile, using the recently-granted "Managed Environment Consumption
//   NCA100 GPUs" quota in eastus.
//
// What this template does (and DOESN'T do):
//   * Creates 0..N Stage-2 Container Apps in this RG, each pinned to the
//     existing CAE referenced by `caeResourceId`. Each app runs on the GPU
//     workload profile `gpuWorkloadProfileName` (default: NC24-A100).
//   * Pulls images from `acrLoginServer` (default: ratioai.azurecr.io) using
//     the CAE's system-assigned managed identity (registries.identity =
//     'system-environment'). The CAE MI must already have AcrPull on that
//     ACR; this template does not grant that role.
//   * Does NOT create CAE, VNet, NAT gateway, NSG, ACR, Content Safety,
//     storage, APIM, or Log Analytics. Reuse the eastus CAE's existing
//     networking and observability.
//   * Does NOT mount NFS. Variants either bake the model into the image or
//     download from HF Hub on first start (HF_TOKEN required for the
//     cache-disabled variant when no NFS mount is available).
//
// Default variant matrix (override via params):
//   1) baked-local   — model + cache baked into the image (offline, fastest cold start)
//   2) baked         — model baked, HF Hub allowed as fallback
//   3) cache-disabled — pulls model from HF Hub at start (slowest, requires HF_TOKEN)
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region. MUST match the location of the existing CAE referenced by caeResourceId.')
param location string = 'eastus'

@description('Tags applied to every resource.')
param tags object = {
  workload: 'contentshield'
  managedBy: 'bicep'
  scenario: 'eastus-gpu-smoke-test'
}

@description('Full resource id of the existing Container Apps Environment to deploy into. Example: /subscriptions/<sid>/resourceGroups/rg-ratio-ai-dev/providers/Microsoft.App/managedEnvironments/cae-ratio-ai-dev-eastus')
param caeResourceId string

@description('GPU workload profile name configured on the target CAE. Confirm the actual name on the env (Container Apps Environment → Workload profiles).')
param gpuWorkloadProfileName string = 'NC24-A100'

@description('Login server of the source ACR holding the contentshield-stage2 image. Default ratioai.azurecr.io.')
param acrLoginServer string = 'ratioai.azurecr.io'

@description('Image repository (path inside ACR). Default contentshield-stage2.')
param imageRepository string = 'contentshield-stage2'

@description('Application Insights connection string. Optional — leave blank if you do not need telemetry on the test apps.')
param appInsightsConnectionString string = ''

@description('Optional Hugging Face token. Required only if a variant needs to download the model from HF Hub at startup (e.g. the cache-disabled variant). Leave empty otherwise.')
@secure()
param hfToken string = ''

@description('Stage-2 variant matrix. Each entry creates one Container App. Shape: { name, tag, minReplicas (default 0), maxReplicas (default 1), needsHfToken (default false), extraEnv (default []) }. Image is built as <acrLoginServer>/<imageRepository>:<tag>.')
param stage2Variants array = [
  {
    name: 'cs-s2-eu-baked-local'
    tag: '1.0.1'
    minReplicas: 1
    maxReplicas: 1
    needsHfToken: false
  }
  {
    name: 'cs-s2-eu-baked'
    tag: '1.0.1'
    minReplicas: 0
    maxReplicas: 1
    needsHfToken: false
  }
  {
    name: 'cs-s2-eu-cache-disabled'
    tag: '1.0.1'
    minReplicas: 0
    maxReplicas: 1
    needsHfToken: true
  }
]

@description('Target port for the Stage-2 wrapper.')
param targetPort int = 8080

@description('ACA HTTP scaler concurrent-requests trigger (per replica).')
param scalerConcurrentRequests string = '30'

@description('ACA scaler cooldown (seconds).')
param scalerCooldownSec int = 600

// -----------------------------------------------------------------------------
// Variant deployments
// -----------------------------------------------------------------------------

module stage2Apps 'modules/stage2AppExternalCae.bicep' = [for (v, i) in stage2Variants: {
  name: 'mod-stage2-eastus-${i}'
  params: {
    location: location
    tags: tags
    caeResourceId: caeResourceId
    acrLoginServer: acrLoginServer
    appInsightsConnectionString: appInsightsConnectionString
    name: v.name
    image: '${acrLoginServer}/${imageRepository}:${v.tag}'
    gpuWorkloadProfileName: gpuWorkloadProfileName
    targetPort: contains(v, 'targetPort') ? v.targetPort : targetPort
    minReplicas: contains(v, 'minReplicas') ? v.minReplicas : 0
    maxReplicas: contains(v, 'maxReplicas') ? v.maxReplicas : 1
    hfToken: (contains(v, 'needsHfToken') && v.needsHfToken) ? hfToken : ''
    extraEnv: contains(v, 'extraEnv') ? v.extraEnv : []
    scalerConcurrentRequests: contains(v, 'scalerConcurrentRequests') ? v.scalerConcurrentRequests : scalerConcurrentRequests
    scalerCooldownSec: contains(v, 'scalerCooldownSec') ? v.scalerCooldownSec : scalerCooldownSec
  }
}]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output stage2Variants array = [for (v, i) in stage2Variants: {
  name: stage2Apps[i]!.outputs.name
  fqdn: stage2Apps[i]!.outputs.fqdn
  principalId: stage2Apps[i]!.outputs.principalId
  image: '${acrLoginServer}/${imageRepository}:${v.tag}'
}]
