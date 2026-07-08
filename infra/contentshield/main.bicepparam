// Bicep parameters file for the ContentShield deployment.
// Edit the values below before deploying. Required values are marked REQUIRED.
using 'main.bicep'

// ── Region & naming ──────────────────────────────────────────────────────────
param location = 'westus3'

// nameSuffix: leave commented to auto-derive a unique suffix from your subscription id
// (default: take(uniqueString(subscription().id), 6) — guarantees globally-unique names).
// Override only if you want a memorable token (3-8 lowercase alphanumeric).
// param nameSuffix = 'mycs01'

param tags = {
  workload: 'contentshield'
  managedBy: 'bicep'
  environment: 'dev'
}

// ── Network (override only if the default address space conflicts) ──────────
param vnetAddressPrefix = '10.40.0.0/16'
param subnetCaePrefix = '10.40.2.0/23'
param subnetGpuPrefix = '10.40.0.0/23'
param subnetApimPrefix = '10.40.4.0/24'

// ── Content Safety / ACR ────────────────────────────────────────────────────
param contentSafetySku = 'S0'
param acrSku = 'Premium'

// ── Container Apps images ───────────────────────────────────────────────────
// Defaults point to mcr quickstart so the first deploy succeeds before you push images.
// After your images are in ACR, set these to e.g. '<acrName>.azurecr.io/contentshield:<tag>'.
param appImage = 'mcr.microsoft.com/k8se/quickstart:latest'
param stage2Image = 'mcr.microsoft.com/k8se/quickstart:latest'
param appTargetPort = 8080
param stage2TargetPort = 8080

// ── Stage-2 variant matrix (A/B/C cold-start test) ──────────────────────────
// When non-empty, deploys ONE Stage-2 Container App per entry (replacing the
// legacy single-Stage-2 path) so we can compare baked-local vs baked vs
// cache-disabled side-by-side on the same NC24-A100 profile.
//
// Each entry uses the friendlyTag set during import. Pin by digest via:
//   scripts/sync-images-from-vendor.ps1 -DigestMap @{
//     'gemma4-31b-model-baked-local-20260519' = 'sha256:60d01ca0...'
//     'gemma4-31b-model-baked-20260519'       = 'sha256:acf084b5...'
//     'gemma4-31b-cache-disabled-20260519'    = 'sha256:11cd054e...'
//   }
//
// IMPORTANT: do NOT put MODEL_NAME or HF_HOME in extraEnv for the baked
// variants — the images self-configure those and overriding them breaks the
// bake (baked-local enforces HF_HUB_OFFLINE=true and will refuse to start).
param stage2Variants = [
  {
    name: 'ca-cs-stage2-baked-local'
    repo: 'contentshield-stage2'
    friendlyTag: 'gemma4-31b-model-baked-local-20260519'
    mountNfs: false
    // Production-facing variant: keep one replica always warm so the steady-
    // state p50 is ~133 ms instead of 22+ minutes on cold-node. The first
    // replica pins one NC24-A100 node (~$3-4/hr 24/7). Burst beyond 30
    // concurrent requests adds a second replica (cold pull on a fresh node,
    // 12-15 min) until the rate subsides.
    minReplicas: 1
    maxReplicas: 2
    scalerConcurrentRequests: '30'
  }
  {
    name: 'ca-cs-stage2-baked'
    repo: 'contentshield-stage2'
    friendlyTag: 'gemma4-31b-model-baked-20260519'
    // Mount the NFS hfcache so vLLM uses it as the model cache when the
    // image's baked cache is partial or stale. Acts as a secondary fallback
    // path when HF Hub isn't reachable (e.g. AME).
    mountNfs: true
    extraEnv: [
      {
        name: 'HF_HOME'
        value: '/mount/csaivllmnfsaxa1/hfcache'
      }
    ]
    minReplicas: 0
    maxReplicas: 1
  }
  {
    name: 'ca-cs-stage2-cache-disabled'
    repo: 'contentshield-stage2'
    friendlyTag: 'gemma4-31b-cache-disabled-20260519'
    // The cache-disabled image has no model baked in. Mounting NFS hfcache
    // makes it AME-friendly: it can use a pre-populated share instead of
    // downloading from HF Hub (which is blocked in AME). When the share is
    // empty, the variant falls back to HF download on first cold start AND
    // writes the result into the NFS share — that warms the cache for
    // subsequent replicas.
    mountNfs: true
    extraEnv: [
      {
        name: 'HF_HOME'
        value: '/mount/csaivllmnfsaxa1/hfcache'
      }
    ]
    minReplicas: 0
    maxReplicas: 1
  }
]

// ── GPU configuration ───────────────────────────────────────────────────────
// Set deployStage2 = false initially if you do not have GPU quota in the target region.
param gpuWorkloadProfileName = 'NC24-A100'
param gpuWorkloadProfileType = 'Consumption-GPU-NC24-A100'
param deployStage2 = true

// Extra IPs to allow on stage-2 ingress. After first deploy, you can append
// the stage-2 app outbound IP (visible via `az containerapp show ... --query properties.outboundIpAddresses`).
param extraStage2AllowedIps = []

// ── Storage (Premium FileStorage + NFS hfcache share) ──────────────────────
// Replica of ratioaivllmnfs from rg-ratio-ai-dev. Mount path inside stage-2 is
// /mount/<storageAccountName>/hfcache and HF_HOME is set accordingly.
param deployStorage = true
// Override storageAccountName if you need an explicit name (3-24 lowercase alphanumeric, globally unique).
// Default = csaivllmnfs<nameSuffix>
// param storageAccountName = 'csaivllmnfsicm'
param hfCacheShareName = 'hfcache'
param hfCacheShareQuotaGiB = 500

// HF token is optional — leave empty to skip the secret. Prefer passing via -HfToken on deploy.ps1.
// param hfToken = '<HF_TOKEN_HERE>'

// Legacy: only used if deployStorage = false (point at an existing external storage).
param nfsServer = ''
param nfsShareName = ''

// ── APIM ────────────────────────────────────────────────────────────────────
// APIM takes 30-45 min. Set deployApim = false for fast iteration.
param deployApim = true
param apimSku = 'StandardV2'
param apimCapacity = 1
param apimPublisherEmail = 'REQUIRED-set-publisher-email@yourcompany.com'
param apimPublisherName = 'ratio'

// ── App registration (RatioAIDev) ───────────────────────────────────────────
// Replace with your own app registration client id (use scripts/create-app-registration.ps1).
param ratioAiDevClientId = 'aceb273b-5301-46a4-91c9-c17ef0ff92e9'
