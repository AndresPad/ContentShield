// Bicep parameters for the eastus GPU smoke test (eastus-gpu-test.bicep).
// Edit the values marked REQUIRED before deploying.
using 'eastus-gpu-test.bicep'

param location = 'eastus'

param tags = {
  workload: 'contentshield'
  managedBy: 'bicep'
  scenario: 'eastus-gpu-smoke-test'
  environment: 'dev'
}

// REQUIRED — full resource id of the existing CAE in eastus.
// Get it via:
//   az containerapp env show -g rg-ratio-ai-dev -n cae-ratio-ai-dev-eastus --query id -o tsv
param caeResourceId = '/subscriptions/REPLACE_SUB_ID/resourceGroups/rg-ratio-ai-dev/providers/Microsoft.App/managedEnvironments/cae-ratio-ai-dev-eastus'

// Confirm the actual workload profile name on the env. Check via:
//   az containerapp env show -g rg-ratio-ai-dev -n cae-ratio-ai-dev-eastus --query 'properties.workloadProfiles[].{name:name,type:workloadProfileType}' -o table
// The quota is "Managed Environment Consumption NCA100 GPUs" → workloadProfileType is "Consumption-GPU-NC24-A100".
param gpuWorkloadProfileName = 'ConsGPUNC24A100'

// Image source. Both ratioai.azurecr.io's image and the CAE managed identity must be reachable from this RG.
// The CAE's system-assigned identity needs AcrPull on this ACR (granted out-of-band, not by this template).
param acrLoginServer = 'ratioai.azurecr.io'
param imageRepository = 'contentshield-stage2'

// Telemetry — optional. Paste the connection string from any App Insights instance you want logs/traces in.
// Leave blank to skip.
param appInsightsConnectionString = ''

// HF token — only used by the cache-disabled variant when it needs to download the model from HF Hub.
// Pass via deploy script (-HfToken) instead of pasting here. Leave blank to skip.
// param hfToken = ''

// Variant matrix. Defaults: 1 image at tag 1.0.1 in three flavours. Adjust `tag` per row if the
// flavours live under different tags (e.g. baked-local-1.0.1 / baked-1.0.1 / cache-disabled-1.0.1).
param stage2Variants = [
  {
    // Baked-local: weights AND HF cache baked into the image. Offline-friendly, fastest cold start.
    // Keep min=1 so we can confirm the GPU node actually attaches and the model serves classify calls.
    name: 'cs-s2-eu-baked-local'
    tag: '1.0.1'
    minReplicas: 1
    maxReplicas: 1
    needsHfToken: false
  }
  {
    // Baked: weights baked, HF Hub allowed as fallback. Idle at zero unless we explicitly scale up.
    name: 'cs-s2-eu-baked'
    tag: '1.0.1'
    minReplicas: 0
    maxReplicas: 1
    needsHfToken: false
  }
  {
    // Cache-disabled: no model in image. Will download from HF Hub on first start.
    // Requires HF_TOKEN (-HfToken on the deploy script) and outbound internet from the CAE subnet.
    name: 'cs-s2-eu-cache-disabled'
    tag: '1.0.1'
    minReplicas: 0
    maxReplicas: 1
    needsHfToken: true
  }
]

param targetPort = 8080
param scalerConcurrentRequests = '30'
param scalerCooldownSec = 600
