// =============================================================================
// ContentShield — End-to-End Infrastructure
// =============================================================================
// Target scope: resourceGroup (existing, NEVER deleted by this template)
//
// Deploys, in dependency order (easy → hard):
//   1. Log Analytics workspace
//   2. Application Insights
//   3. Content Safety (Azure AI)
//   4. Public IP + NAT Gateway
//   5. Network Security Groups
//   6. Virtual Network (with 3 subnets)
//   7. Azure Container Registry
//   8. Container Apps Environment (workload profiles: Consumption + NC24-A100 GPU)
//   9. Container Apps (ca-ratio-contentshield + ca-contentshield-stage2 on GPU)
//  10. API Management
// =============================================================================

targetScope = 'resourceGroup'

// ── Core parameters ──────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'westus3'

@description('Globally-unique suffix appended to resources that require unique names (ACR, Content Safety, APIM, etc.). Default: a deterministic 6-char hash of your subscription id, guaranteeing uniqueness across customers. Override with your own short alphanumeric token.')
param nameSuffix string = take(uniqueString(subscription().id), 6)

@description('Tags applied to every resource.')
param tags object = {
  workload: 'contentshield'
  managedBy: 'bicep'
}

// ── Resource naming (override only if you need different names) ──────────────

@description('Log Analytics workspace name.')
param logAnalyticsName string = 'log-contentshield-${nameSuffix}'

@description('Application Insights name.')
param appInsightsName string = 'appi-contentshield-${nameSuffix}'

@description('Content Safety account name (must be globally unique).')
param contentSafetyName string = 'cs-ai-contentsafety-${nameSuffix}'

@description('Public IP name (regional uniqueness only).')
param publicIpName string = 'CONTENTSHIELD-NATGW-PIP'

@description('NAT Gateway name.')
param natGatewayName string = 'CONTENTSHIELD-NATGW-WUS3'

@description('Main NSG name.')
param nsgMainName string = 'NSG-contentshield-westus3'

@description('GPU subnet NSG name.')
param nsgGpuName string = 'NSG-contentshield-vllm-gpu-subnet-westus3'

@description('Virtual network name.')
param vnetName string = 'vnet-contentshield-westus3'

@description('Azure Container Registry name (lowercase alphanumeric only, globally unique).')
param acrName string = 'contentshieldacr${nameSuffix}'

@description('Container Apps Environment name.')
param caeName string = 'cae-contentshield-${nameSuffix}'

@description('Main application Container App name.')
param appName string = 'ca-ratio-contentshield'

@description('Stage-2 GPU Container App name.')
param stage2AppName string = 'ca-contentshield-stage2'

@description('API Management service name (globally unique).')
param apimName string = 'apim-contentshield-${nameSuffix}'

@description('Premium FileStorage account name for NFS hfcache share (globally unique, 3-24 lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string = toLower('csaivllmnfs${nameSuffix}')

@description('NFS file share name on the storage account.')
param hfCacheShareName string = 'hfcache'

@description('Quota for the NFS share, GiB.')
param hfCacheShareQuotaGiB int = 500

// ── Network parameters ──────────────────────────────────────────────────────

@description('VNet address space.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Subnet for Container Apps Environment (workload profile, non-GPU).')
param subnetCaePrefix string = '10.40.2.0/23'

@description('Subnet reserved for GPU workloads (Microsoft.Storage service endpoint).')
param subnetGpuPrefix string = '10.40.0.0/23'

@description('Subnet for APIM v2 (delegated to Microsoft.Web/serverFarms).')
param subnetApimPrefix string = '10.40.4.0/24'

// ── Content Safety ──────────────────────────────────────────────────────────

@description('Content Safety SKU.')
param contentSafetySku string = 'S0'

// ── ACR ─────────────────────────────────────────────────────────────────────

@description('ACR SKU. Premium needed for zone-redundancy and private endpoints.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Premium'

// ── Container Apps ──────────────────────────────────────────────────────────

@description('Image for ca-ratio-contentshield. Defaults to mcr quickstart so the template can deploy before customer images are pushed. Overridden by appImageTag when that is non-empty.')
param appImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Image for ca-contentshield-stage2 (GPU). Defaults to mcr quickstart. Overridden by stage2ImageTag when that is non-empty.')
param stage2Image string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Tag for ca-ratio-contentshield in the customer ACR. When non-empty, builds the full image reference as "<acrLoginServer>/contentshield:<tag>" and overrides appImage. Leave empty to use appImage as-is (placeholder/dev).')
param appImageTag string = ''

@description('Tag for ca-contentshield-stage2 in the customer ACR. When non-empty, builds the full image reference as "<acrLoginServer>/contentshield-stage2:<tag>" and overrides stage2Image. Leave empty to use stage2Image as-is (placeholder/dev).')
param stage2ImageTag string = ''

@description('Target port for ca-ratio-contentshield.')
param appTargetPort int = 8080

@description('Target port for ca-contentshield-stage2.')
param stage2TargetPort int = 8080

@description('GPU workload profile name. Default NC24-A100. Set to empty string to skip the GPU profile (and skip stage2 GPU deployment).')
param gpuWorkloadProfileName string = 'NC24-A100'

@description('GPU workload profile type. Common: Consumption-GPU-NC24-A100, Consumption-GPU-NC8as-T4.')
param gpuWorkloadProfileType string = 'Consumption-GPU-NC24-A100'

@description('Deploy the stage-2 GPU container app. Set false to skip (e.g., during initial testing if GPU quota unavailable).')
param deployStage2 bool = true

@description('Variant matrix for Stage-2. When this array is non-empty, the legacy single Stage-2 app in modules/containerApps.bicep is skipped and one Microsoft.App/containerApps resource is created per entry via modules/stage2App.bicep. Each entry shape: { name, repo, friendlyTag (or digest), mountNfs, minReplicas, maxReplicas, hfToken (string, optional), extraEnv (array, optional) }. The image reference is built as <acrLoginServer>/<repo>:<friendlyTag>. Pin by digest by importing under a friendly tag (see scripts/sync-images-from-vendor.ps1 -DigestMap) and then reference that friendlyTag here.')
param stage2Variants array = []

@description('Extra IP CIDR ranges to add to stage-2 ingress allowlist (e.g., the stage-2 app outbound IP after first deploy).')
param extraStage2AllowedIps array = []

@description('Optional Hugging Face token for stage-2 model download. Leave empty to skip the secret.')
@secure()
param hfToken string = ''

@description('Optional NFS Azure Files server (e.g., mystorage.file.core.windows.net) used to mount HF cache for stage-2. Leave empty to skip storage mount.')
param nfsServer string = ''

@description('Optional NFS share path (e.g., /mystorage/hfcache). Leave empty to skip storage mount.')
param nfsShareName string = ''

@description('Model name advertised to the main app (SLM_MODEL) and served by stage-2 (MODEL_NAME).')
param slmModel string = 'google/gemma-4-31b-it'

@description('Feature flag CONTENTSHIELD_V1_ML_DISABLED on the main app. "1" disables the legacy ML path; "0" re-enables it.')
param contentshieldV1MlDisabled string = '1'

@description('Deploy a brand-new Premium FileStorage account + NFS hfcache share inside this RG. When true, the values of nfsServer/nfsShareName are ignored and computed from the new storage account.')
param deployStorage bool = true

@description('Deploy the HuggingFace cache pre-warm job. The job runs on demand (kicked off by deploy.ps1) and populates the NFS hfcache share with the stage-2 SLM weights so the first GPU cold start skips the multi-minute download. Requires deployStorage=true and deployStage2=true to be useful.')
param deployHfPrewarmJob bool = true

@description('Container Apps Job name for the HF cache pre-warm.')
param hfPrewarmJobName string = 'job-hf-prewarm'

// ── APIM ────────────────────────────────────────────────────────────────────

@description('APIM SKU. StandardV2 supports VNet integration in West US 3.')
@allowed([
  'StandardV2'
  'PremiumV2'
  'BasicV2'
])
param apimSku string = 'StandardV2'

@description('APIM capacity (units).')
param apimCapacity int = 1

@description('APIM publisher email.')
param apimPublisherEmail string

@description('APIM publisher name.')
param apimPublisherName string = 'ratio'

@description('Deploy API Management. Slow (~30-45 min). Set false to skip during iterative testing.')
param deployApim bool = true

@description('AAD tenant id stamped into APIM named values (used by validate-azure-ad-token policy). Defaults to the tenant the deployment is running in.')
param aadTenantId string = subscription().tenantId

@description('AAD audience that the APIM policy validates incoming bearer tokens against. Defaults to ratioAiDevClientId — set to the API app registration client id for production.')
param aadApiAudience string = ''

@description('AAD client (application) id of the API. Stored as an APIM named value. Defaults to ratioAiDevClientId.')
param aadApiClientId string = ''

// ── App registration (RatioAIDev) ───────────────────────────────────────────

@description('Client (Application) ID of the Entra app registration RatioAIDev. Exposed to container apps as RATIO_AI_DEV_CLIENT_ID.')
param ratioAiDevClientId string = 'aceb273b-5301-46a4-91c9-c17ef0ff92e9'

// ============================================================================
// Modules
// ============================================================================

// 1. Log Analytics
module monitoring 'modules/monitoring.bicep' = {
  name: 'mod-monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
  }
}

// 2. Content Safety
module contentSafety 'modules/contentSafety.bicep' = {
  name: 'mod-contentsafety'
  params: {
    location: location
    tags: tags
    name: contentSafetyName
    sku: contentSafetySku
  }
}

// 3. Network (PIP → NAT GW → NSGs → VNet)
module network 'modules/network.bicep' = {
  name: 'mod-network'
  params: {
    location: location
    tags: tags
    publicIpName: publicIpName
    natGatewayName: natGatewayName
    nsgMainName: nsgMainName
    nsgGpuName: nsgGpuName
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    subnetCaePrefix: subnetCaePrefix
    subnetGpuPrefix: subnetGpuPrefix
    subnetApimPrefix: subnetApimPrefix
  }
}

// 3b. Storage (Premium FileStorage + NFS hfcache share)
module storage 'modules/storage.bicep' = if (deployStorage) {
  name: 'mod-storage'
  params: {
    location: location
    tags: tags
    name: storageAccountName
    shareName: hfCacheShareName
    shareQuotaGiB: hfCacheShareQuotaGiB
    allowedSubnetIds: [
      network.outputs.caeSubnetId
      network.outputs.gpuSubnetId
    ]
  }
}

// Resolve final NFS endpoint to wire into the CAE storage mount.
var effectiveNfsServer = deployStorage ? storage!.outputs.fileEndpointHost : nfsServer
var effectiveNfsShareName = deployStorage ? storage!.outputs.nfsSharePath : nfsShareName
var effectiveStorageAccountName = deployStorage ? storage!.outputs.name : ''

// 4. ACR
module acr 'modules/acr.bicep' = {
  name: 'mod-acr'
  params: {
    location: location
    tags: tags
    name: acrName
    sku: acrSku
  }
}

// Resolve effective images: if a tag is supplied, point at the customer ACR;
// otherwise fall back to the explicit appImage / stage2Image (placeholder or
// hand-set value). Keeps two-phase deploy working: phase 1 uses defaults,
// phase 2 supplies tags after import.
var effectiveAppImage = empty(appImageTag) ? appImage : '${acr.outputs.loginServer}/contentshield:${appImageTag}'
var effectiveStage2Image = empty(stage2ImageTag) ? stage2Image : '${acr.outputs.loginServer}/contentshield-stage2:${stage2ImageTag}'

// 5. Container Apps Environment (depends on network + monitoring)
module cae 'modules/containerAppsEnv.bicep' = {
  name: 'mod-cae'
  params: {
    location: location
    tags: tags
    name: caeName
    infrastructureSubnetId: network.outputs.caeSubnetId
    logAnalyticsCustomerId: monitoring.outputs.logAnalyticsCustomerId
    logAnalyticsSharedKey: monitoring.outputs.logAnalyticsSharedKey
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    gpuWorkloadProfileName: gpuWorkloadProfileName
    gpuWorkloadProfileType: gpuWorkloadProfileType
    nfsServer: effectiveNfsServer
    nfsShareName: effectiveNfsShareName
  }
}

// Variant-matrix flag. When true (stage2Variants is non-empty), the legacy
// single-Stage-2 path in modules/containerApps.bicep is suppressed and we
// instantiate modules/stage2App.bicep once per entry below.
var useStage2Variants = !empty(stage2Variants)

// 6. Container Apps (depends on CAE + ACR + Content Safety)
module apps 'modules/containerApps.bicep' = {
  name: 'mod-apps'
  params: {
    location: location
    tags: tags
    caeName: cae.outputs.name
    acrLoginServer: acr.outputs.loginServer
    acrResourceId: acr.outputs.id
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    contentSafetyEndpoint: contentSafety.outputs.endpoint
    contentSafetyResourceId: contentSafety.outputs.id
    ratioAiDevClientId: ratioAiDevClientId
    appName: appName
    appImage: effectiveAppImage
    appTargetPort: appTargetPort
    natGatewayPublicIp: network.outputs.natGatewayPublicIp
    caeStaticIp: cae.outputs.staticIp
    extraStage2AllowedIps: extraStage2AllowedIps
    slmModel: slmModel
    contentshieldV1MlDisabled: contentshieldV1MlDisabled
    deployStage2: deployStage2 && !useStage2Variants
    stage2AppName: stage2AppName
    stage2Image: effectiveStage2Image
    stage2TargetPort: stage2TargetPort
    gpuWorkloadProfileName: gpuWorkloadProfileName
    hfToken: hfToken
    nfsStorageMounted: !empty(effectiveNfsServer) && !empty(effectiveNfsShareName)
    storageAccountName: effectiveStorageAccountName
    hfCacheShareName: hfCacheShareName
  }
}

// 6c. Stage-2 variant matrix. One Container App per entry in stage2Variants[].
//     Each variant inherits the image's own MODEL_NAME/HF_HOME/PROMPT_PATH env;
//     this module only injects tuneables + observability + optional HF_TOKEN +
//     caller-supplied extraEnv. See modules/stage2App.bicep header for details.
module stage2Apps 'modules/stage2App.bicep' = [for (v, i) in stage2Variants: if (deployStage2 && useStage2Variants) {
  name: 'mod-stage2-${i}'
  params: {
    location: location
    tags: tags
    caeName: cae.outputs.name
    acrLoginServer: acr.outputs.loginServer
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    natGatewayPublicIp: network.outputs.natGatewayPublicIp
    caeStaticIp: cae.outputs.staticIp
    extraAllowedIps: extraStage2AllowedIps
    name: v.name
    image: '${acr.outputs.loginServer}/${v.repo}:${v.friendlyTag}'
    gpuWorkloadProfileName: gpuWorkloadProfileName
    targetPort: contains(v, 'targetPort') ? v.targetPort : stage2TargetPort
    mountNfs: contains(v, 'mountNfs') ? v.mountNfs : false
    storageAccountName: effectiveStorageAccountName
    hfCacheShareName: hfCacheShareName
    minReplicas: contains(v, 'minReplicas') ? v.minReplicas : 0
    maxReplicas: contains(v, 'maxReplicas') ? v.maxReplicas : 1
    hfToken: contains(v, 'hfToken') ? v.hfToken : ''
    extraEnv: contains(v, 'extraEnv') ? v.extraEnv : []
    scalerConcurrentRequests: contains(v, 'scalerConcurrentRequests') ? v.scalerConcurrentRequests : '30'
    scalerCooldownSec: contains(v, 'scalerCooldownSec') ? v.scalerCooldownSec : 600
  }
}]

// 6b. HF cache pre-warm job (manual-trigger; fired by deploy.ps1 post-deploy)
module hfPrewarmJob 'modules/hfPrewarmJob.bicep' = if (deployHfPrewarmJob && deployStorage && deployStage2) {
  name: 'mod-hfprewarm'
  params: {
    location: location
    tags: tags
    caeName: cae.outputs.name
    jobName: hfPrewarmJobName
    model: slmModel
    storageAccountName: effectiveStorageAccountName
    hfCacheShareName: hfCacheShareName
    hfToken: hfToken
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
  }
  dependsOn: [
    apps
  ]
}

// 7. APIM (slowest — last; depends on VNet subnet)
module apim 'modules/apim.bicep' = if (deployApim) {
  name: 'mod-apim'
  params: {
    location: location
    tags: tags
    name: apimName
    sku: apimSku
    capacity: apimCapacity
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    subnetId: network.outputs.apimSubnetId
    caeDefaultDomain: cae.outputs.defaultDomain
    backendAppName: appName
    aadTenantId: aadTenantId
    aadApiAudience: empty(aadApiAudience) ? ratioAiDevClientId : aadApiAudience
    aadApiClientId: empty(aadApiClientId) ? ratioAiDevClientId : aadApiClientId
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
  }
}

// ============================================================================
// Outputs
// ============================================================================

output logAnalyticsId string = monitoring.outputs.logAnalyticsId
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
output contentSafetyEndpoint string = contentSafety.outputs.endpoint
output contentSafetyPrincipalId string = contentSafety.outputs.principalId
output natGatewayPublicIp string = network.outputs.natGatewayPublicIp
output vnetId string = network.outputs.vnetId
output acrLoginServer string = acr.outputs.loginServer
output acrPrincipalId string = acr.outputs.principalId
output caeName string = cae.outputs.name
output caeDefaultDomain string = cae.outputs.defaultDomain
output appFqdn string = apps.outputs.appFqdn
output appPrincipalId string = apps.outputs.appPrincipalId
output stage2Fqdn string = apps.outputs.stage2Fqdn
output stage2PrincipalId string = apps.outputs.stage2PrincipalId
output stage2Variants array = [for (v, i) in stage2Variants: (deployStage2 && useStage2Variants) ? {
  name: stage2Apps[i]!.outputs.name
  fqdn: stage2Apps[i]!.outputs.fqdn
  principalId: stage2Apps[i]!.outputs.principalId
  image: '${acr.outputs.loginServer}/${v.repo}:${v.friendlyTag}'
} : {
  name: v.name
  fqdn: ''
  principalId: ''
  image: ''
}]
output apimGatewayUrl string = deployApim ? apim!.outputs.gatewayUrl : ''
output apimPrincipalId string = deployApim ? apim!.outputs.principalId : ''
output storageAccountName string = deployStorage ? storage!.outputs.name : ''
output storageNfsHost string = deployStorage ? storage!.outputs.fileEndpointHost : ''
output storageNfsSharePath string = deployStorage ? storage!.outputs.nfsSharePath : ''
output hfCacheMountPath string = deployStorage ? '/mount/${storage!.outputs.name}/${hfCacheShareName}' : ''
output hfPrewarmJobName string = (deployHfPrewarmJob && deployStorage && deployStage2) ? hfPrewarmJob!.outputs.jobName : ''
