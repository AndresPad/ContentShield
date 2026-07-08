#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploy the ContentShield eastus GPU smoke test (eastus-gpu-test.bicep).

.DESCRIPTION
  Creates 1..N Stage-2 Container Apps in -ResourceGroup (default
  rg-contentshield) that target the EXISTING Container Apps Environment in
  eastus (default cae-ratio-ai-dev-eastus / rg-ratio-ai-dev). Each app runs
  on the Consumption-GPU-NC24-A100 workload profile so we can validate that:
    1. The recently-granted "Managed Environment Consumption NCA100 GPUs"
       quota actually schedules GPU nodes.
    2. ContentShield Stage-2 images pull from ratioai.azurecr.io.
    3. vLLM boots, attaches the A100, and /classify returns inference results.

  This script does NOT:
    * Create the CAE, VNet, ACR, or storage. Those are reused from the
      existing rg-ratio-ai-dev infra.
    * Grant AcrPull from the CAE's managed identity to ratioai.azurecr.io —
      see the role-assignment hint at the bottom of this header.
    * Touch the production westus3 stack (main.bicep / main.bicepparam).

.PARAMETER SubscriptionId
  Azure subscription ID. If omitted, uses the current az CLI context.

.PARAMETER ResourceGroup
  Target resource group for the new Container Apps. MUST exist. Default rg-contentshield.

.PARAMETER CaeResourceGroup
  Resource group that owns the existing CAE. Default rg-ratio-ai-dev.

.PARAMETER CaeName
  Name of the existing CAE. Default cae-ratio-ai-dev-eastus.

.PARAMETER GpuWorkloadProfileName
  Workload profile name on the CAE that maps to NC24-A100. Default 'NC24-A100'.
  Confirm the actual name with:
    az containerapp env show -g <CaeRG> -n <CaeName> --query 'properties.workloadProfiles' -o table

.PARAMETER AcrLoginServer
  Source ACR. Default ratioai.azurecr.io.

.PARAMETER ImageRepository
  Image repo path inside the ACR. Default contentshield-stage2.

.PARAMETER ImageTag
  Tag for ALL variants (overrides the per-variant tags in the bicepparam).
  Leave empty to use whatever tags are pinned in eastus-gpu-test.bicepparam.

.PARAMETER AppInsightsConnectionString
  Optional App Insights connection string. Leave empty to skip telemetry.

.PARAMETER HfToken
  Hugging Face token, passed as a secure parameter. Required if any variant
  has needsHfToken=true (e.g. cache-disabled) and no NFS share is mounted.

.PARAMETER WhatIf
  Show what would be deployed without applying changes.

.EXAMPLE
  .\deploy-eastus-gpu-test.ps1 -ResourceGroup rg-contentshield

.EXAMPLE
  # Pass an HF token so the cache-disabled variant can download from HF Hub
  .\deploy-eastus-gpu-test.ps1 -ResourceGroup rg-contentshield -HfToken (Get-Content .\.hf-token -Raw).Trim()

.EXAMPLE
  # Pin all three variants to the same tag (e.g. you only have :1.0.1 published today)
  .\deploy-eastus-gpu-test.ps1 -ResourceGroup rg-contentshield -ImageTag '1.0.1'

.NOTES
  AcrPull grant (one-time, OUTSIDE this script):
    The CAE's system-assigned identity needs AcrPull on ratioai.azurecr.io for
    image pulls to succeed. If pulls fail with auth errors, run (with sufficient
    permissions on the source ACR):

      $envMiPid = az containerapp env show -g <CaeRG> -n <CaeName> --query 'identity.principalId' -o tsv
      $acrId    = az acr show --name ratioai --query id -o tsv
      az role assignment create --assignee-object-id $envMiPid --assignee-principal-type ServicePrincipal `
        --role AcrPull --scope $acrId
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup = 'rg-contentshield',
    [string]$CaeResourceGroup = 'rg-ratio-ai-dev',
    [string]$CaeName = 'cae-ratio-ai-dev-eastus',
    [string]$GpuWorkloadProfileName = 'ConsGPUNC24A100',
    [string]$AcrLoginServer = 'ratioai.azurecr.io',
    [string]$ImageRepository = 'contentshield-stage2',
    [string]$ImageTag = '',
    [string]$AppInsightsConnectionString = '',
    [string]$HfToken = ''
)

$ErrorActionPreference = 'Stop'

# 1. Subscription context ------------------------------------------------------
if ($SubscriptionId) {
    Write-Host "[deploy-eastus-gpu-test] az account set -s $SubscriptionId"
    az account set --subscription $SubscriptionId | Out-Null
}
$ctx = az account show --query '{id:id,name:name}' -o json | ConvertFrom-Json
Write-Host "[deploy-eastus-gpu-test] Using subscription: $($ctx.name) ($($ctx.id))"

# 2. Resolve existing CAE ------------------------------------------------------
Write-Host "[deploy-eastus-gpu-test] Resolving CAE $CaeResourceGroup/$CaeName"
$caeId = az containerapp env show -g $CaeResourceGroup -n $CaeName --query id -o tsv
if (-not $caeId) {
    throw "Could not resolve CAE $CaeResourceGroup/$CaeName. Check the RG/name and your context."
}
$caeLocation = az containerapp env show -g $CaeResourceGroup -n $CaeName --query location -o tsv
Write-Host "[deploy-eastus-gpu-test] CAE id      : $caeId"
Write-Host "[deploy-eastus-gpu-test] CAE region  : $caeLocation"

# 3. Verify the GPU workload profile is configured on the CAE -----------------
$profilesJson = az containerapp env show -g $CaeResourceGroup -n $CaeName --query 'properties.workloadProfiles' -o json
$profiles = $profilesJson | ConvertFrom-Json
$gpuProfile = $profiles | Where-Object { $_.name -eq $GpuWorkloadProfileName }
if (-not $gpuProfile) {
    Write-Warning "Workload profile '$GpuWorkloadProfileName' not found on CAE. Profiles present:"
    $profiles | ForEach-Object { Write-Warning "  - $($_.name) ($($_.workloadProfileType))" }
    Write-Warning "Add it via Portal (CAE → Workload profiles) or:"
    Write-Warning "  az containerapp env workload-profile add -g $CaeResourceGroup -n $CaeName --workload-profile-name $GpuWorkloadProfileName --workload-profile-type Consumption-GPU-NC24-A100"
    Write-Warning "Continuing anyway — the deployment will fail with a clearer error if the profile is still missing."
}
else {
    Write-Host "[deploy-eastus-gpu-test] Workload profile OK: $($gpuProfile.name) ($($gpuProfile.workloadProfileType))"
}

# 4. Verify target RG exists ---------------------------------------------------
$rgExists = az group exists -n $ResourceGroup
if ($rgExists -ne 'true') {
    throw "Target resource group '$ResourceGroup' does not exist. Create it first or pick a different RG."
}

# 5. Build parameter overrides -------------------------------------------------
$paramFile = Join-Path $PSScriptRoot 'eastus-gpu-test.bicepparam'
if (-not (Test-Path $paramFile)) {
    throw "Param file not found: $paramFile"
}

$paramOverrides = @(
    "caeResourceId=$caeId",
    "gpuWorkloadProfileName=$GpuWorkloadProfileName",
    "acrLoginServer=$AcrLoginServer",
    "imageRepository=$ImageRepository",
    "location=$caeLocation"
)
if ($AppInsightsConnectionString) {
    $paramOverrides += "appInsightsConnectionString=$AppInsightsConnectionString"
}

# Optional: rewrite all variant tags to a single ImageTag.
if ($ImageTag) {
    Write-Host "[deploy-eastus-gpu-test] Pinning all variants to tag: $ImageTag"
    $variants = @(
        @{ name = 'cs-s2-eu-baked-local';    tag = $ImageTag; minReplicas = 1; maxReplicas = 1; needsHfToken = $false },
        @{ name = 'cs-s2-eu-baked';          tag = $ImageTag; minReplicas = 0; maxReplicas = 1; needsHfToken = $false },
        @{ name = 'cs-s2-eu-cache-disabled'; tag = $ImageTag; minReplicas = 0; maxReplicas = 1; needsHfToken = $true }
    )
    $variantsJson = ($variants | ConvertTo-Json -Compress -Depth 5)
    $paramOverrides += "stage2Variants=$variantsJson"
}

if ($HfToken) {
    $paramOverrides += "hfToken=$HfToken"
}

# 6. WhatIf or deploy ----------------------------------------------------------
$bicepFile = Join-Path $PSScriptRoot 'eastus-gpu-test.bicep'
$deployName = "contentshield-eastus-gpu-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$cmd = @(
    'az','deployment','group','create',
    '--resource-group', $ResourceGroup,
    '--name', $deployName,
    '--template-file', $bicepFile,
    '--parameters', $paramFile
)
foreach ($p in $paramOverrides) {
    $cmd += '--parameters'
    $cmd += $p
}

if ($WhatIfPreference) {
    $cmd[2] = 'what-if'  # az deployment group what-if
    Write-Host "[deploy-eastus-gpu-test] What-If: $($cmd -join ' ')"
}
else {
    Write-Host "[deploy-eastus-gpu-test] Deploying: $deployName"
}

& $cmd[0] $cmd[1..($cmd.Length - 1)]
if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed with exit code $LASTEXITCODE."
}

if ($WhatIfPreference) {
    Write-Host "[deploy-eastus-gpu-test] What-If complete."
    return
}

# 7. Print outputs -------------------------------------------------------------
$outputs = az deployment group show -g $ResourceGroup -n $deployName --query properties.outputs -o json | ConvertFrom-Json
if ($outputs.stage2Variants) {
    Write-Host "`n[deploy-eastus-gpu-test] Deployed Stage-2 variants:"
    foreach ($v in $outputs.stage2Variants.value) {
        Write-Host ("  - {0,-40} {1}" -f $v.name, $v.fqdn)
        Write-Host ("    image:        {0}" -f $v.image)
        Write-Host ("    principalId:  {0}" -f $v.principalId)
    }
}

Write-Host "`n[deploy-eastus-gpu-test] Smoke test next steps:"
Write-Host "  1. Wait for the GPU replica to come up (12–20 min cold start on baked, longer on cache-disabled)."
Write-Host "     az containerapp revision list -g $ResourceGroup -n ca-cs-stage2-eastus-baked-local -o table"
Write-Host "  2. Tail logs (look for 'Application startup complete' from FastAPI and 'Engine 0 added new request' from vLLM):"
Write-Host "     az containerapp logs show -g $ResourceGroup -n ca-cs-stage2-eastus-baked-local --tail 200 --follow"
Write-Host "  3. Hit /classify from inside the CAE (the apps use internal ingress). Easiest: az containerapp exec into the orchestrator or a debug container in the same env."
