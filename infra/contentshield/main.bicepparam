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
// Placeholder defaults so a first "empty ACR" deploy still succeeds. The real
// images are chosen by tag below and imported into the customer ACR by
// deploy.ps1 (server-side `az acr import` from the vendor ACR).
param appImage = 'mcr.microsoft.com/k8se/quickstart:latest'
param stage2Image = 'mcr.microsoft.com/k8se/quickstart:latest'
param appTargetPort = 8080
param stage2TargetPort = 8080

// Orchestrator (contentshield repo) image tag in the customer ACR.
param appImageTag = '1.0.2'

// ── Stage-2 backend selection (THE ICM HANDOFF SWITCH) ──────────────────────
// stage2Mode picks which Stage-2 backend(s) to deploy:
//   'slm-gpu'  → GPU vLLM (Gemma). Needs A100 GPU quota. From Dockerfile.slm-gpu.
//   'aoai-cpu' → CPU wrapper over Azure OpenAI gpt-4o. No GPU. From Dockerfile.aoai-cpu.
//   'both'     → deploy both side-by-side (this demo RG).
//   'none'     → skip Stage-2.
// ICM teams typically set this to 'slm-gpu' OR 'aoai-cpu'. Override on the CLI
// with deploy.ps1 -Stage2Mode <mode>.
param stage2Mode = 'both'

// When both are deployed, which one the orchestrator routes to (SLM_ENDPOINT).
// Flip to 'slm-gpu' (revision-only change) to demo the GPU path end-to-end.
param orchestratorStage2Target = 'aoai-cpu'

// Stage-2 image tags in the customer ACR (contentshield-stage2 repo).
param slmGpuStage2ImageTag = '1.0.3-dev.20260714b-slm-gpu'
param aoaiCpuStage2ImageTag = '1.0.3-dev.20260715-sdk-retry-aoai-cpu'

// ── Azure OpenAI (used only by the aoai-cpu Stage-2) ────────────────────────
// The aoai-cpu wrapper calls this gpt-4o deployment. RBAC (Cognitive Services
// OpenAI User) on the account is granted by deploy.ps1 -AzureOpenAiResourceId,
// or pass -AzureOpenAiApiKey to use key auth instead of managed identity.
param azureOpenAiEndpoint = 'https://ratioaifoundrycentralus.cognitiveservices.azure.com/'
param azureOpenAiDeployment = 'gpt-4o'
param azureOpenAiApiVersion = '2024-10-21'

// ── Advanced: legacy GPU variant matrix (A/B cold-start testing) ────────────
// Leave EMPTY to use the clean stage2Mode path above. When non-empty it takes
// precedence and deploys one GPU Container App per entry (see modules/stage2App.bicep).
param stage2Variants = []

// ── GPU configuration ───────────────────────────────────────────────────────
// Set deployStage2 = false initially if you do not have GPU quota in the target region.
param gpuWorkloadProfileName = 'NC24-A100'
param gpuWorkloadProfileType = 'Consumption-GPU-NC24-A100'
param deployStage2 = true

// Extra IPs to allow on stage-2 ingress. After first deploy, you can append
// the stage-2 app outbound IP (visible via `az containerapp show ... --query properties.outboundIpAddresses`).
param extraStage2AllowedIps = []

// ── Storage (Premium FileStorage + NFS hfcache share) ──────────────────────
// Only needed when a GPU Stage-2 image downloads its model at runtime and
// caches it on NFS. The slm-gpu image (1.0.3-dev.*-slm-gpu) is fully baked /
// offline, and the aoai-cpu image has no local model — so storage is OFF here.
// Set true only if you switch to a non-baked GPU image that needs hfcache.
param deployStorage = false
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
