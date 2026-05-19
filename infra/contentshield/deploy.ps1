#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploy the ContentShield infrastructure to an Azure resource group.

.DESCRIPTION
  Deploys infra/contentshield/main.bicep into an existing resource group.
  Optionally resets (deletes all child resources) the RG first via -Reset.

  The resource group itself is NEVER deleted (role assignments preserved).

.PARAMETER SubscriptionId
  Azure subscription ID to target. If omitted, uses the current az CLI context.

.PARAMETER ResourceGroup
  Target resource group. MUST already exist.

.PARAMETER Location
  Azure region. Default westus3.

.PARAMETER NameSuffix
  Suffix applied to globally-unique resources. Default 'icm'.

.PARAMETER ApimPublisherEmail
  REQUIRED — publisher email for APIM.

.PARAMETER HfToken
  Optional Hugging Face token, passed securely as a Bicep secure parameter.

.PARAMETER Reset
  Delete ALL resources in the RG before deploying (RG itself preserved).

.PARAMETER SkipApim
  Skip APIM deployment (fast iteration).

.PARAMETER SkipStage2
  Skip the GPU stage-2 container app (no GPU quota).

.PARAMETER WhatIf
  Show what would be deployed without applying changes.

.EXAMPLE
  .\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail me@contoso.com

.EXAMPLE
  .\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail me@contoso.com -Reset -SkipApim
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'westus3',
    [string]$NameSuffix,
    [Parameter(Mandatory)][string]$ApimPublisherEmail,
    [string]$HfToken = '',

    # ── Vendor image-pull credentials (optional). When provided, deploy.ps1
    #    auto-imports vendor images into the customer's ACR before container
    #    apps are pointed at them.
    [string]$VendorAcrFqdn,
    [string]$VendorAcrTokenName,
    [string]$VendorAcrTokenPassword,
    [string]$ImageTag = 'latest',
    [switch]$AllTags,
    # When set, vendor ACR import uses the current az login identity (AAD/MI)
    # instead of a scoped token. Intended for internal-Microsoft customers in
    # the same AAD tenant as the vendor ACR. -VendorAcrTokenName/-Password
    # become optional.
    [switch]$UseAad,

    # ── Weights (OCI artifact) sync ──────────────────────────────────────────
    # When -VendorAcrFqdn is set, also copy contentshield-stage2-weights:<Tag>
    # from the vendor ACR into the customer ACR via `oras copy` (AAD or token).
    # Phase-2 then wires the prewarm job with modelSource=acr-oras so it
    # hydrates the customer NFS share from the customer ACR — NOT HuggingFace.
    [bool]$SyncWeights = $true,
    [string]$WeightsRepository = 'contentshield-stage2-weights',
    # Falls back to $ImageTag when empty.
    [string]$WeightsTag = '',

    [switch]$Reset,
    [switch]$SkipApim,
    [switch]$SkipStage2,
    [switch]$SkipPreflight,
    [switch]$SkipImageImport,
    [bool]$EnableArtifactStreaming = $true,
    # If $true, fire the HF cache pre-warm Container Apps Job after deploy so
    # the stage-2 NFS share is populated with model weights before any real
    # cold start hits. Idempotent; safe to re-run.
    [bool]$PrewarmHfCache = $true,
    # If $true, block until the pre-warm job completes (success or fail).
    # Default $false so deploy returns quickly; the job continues in background.
    [switch]$WaitForPrewarm,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$infraDir = $PSScriptRoot

Write-Host "`n======================================" -ForegroundColor Cyan
Write-Host "  ContentShield — Azure Deployment" -ForegroundColor Cyan
Write-Host "======================================`n" -ForegroundColor Cyan

# ── Step 1: az context ──────────────────────────────────────────────────────
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged into Azure CLI. Run 'az login'." }
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Write-Host "Switching subscription to $SubscriptionId" -ForegroundColor Yellow
    az account set --subscription $SubscriptionId | Out-Null
    $account = az account show -o json | ConvertFrom-Json
}
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# ── Step 2: pre-flight checks (resource providers, quota, permissions) ──────
if (-not $SkipPreflight) {
    & (Join-Path $infraDir 'scripts\preflight.ps1') `
        -ResourceGroup $ResourceGroup `
        -Location $Location `
        -CheckGpuQuota:(-not $SkipStage2)
    if ($LASTEXITCODE -ne 0) { throw "Pre-flight failed. Re-run with -SkipPreflight to override (not recommended)." }
}

# ── Step 3: containerapp extension ──────────────────────────────────────────
$ext = az extension list --query "[?name=='containerapp'].name" -o tsv 2>$null
if (-not $ext) {
    Write-Host "Installing containerapp extension..." -ForegroundColor Yellow
    az extension add --name containerapp --upgrade --yes --only-show-errors | Out-Null
}

# ── Step 4: verify RG exists (never create here) ────────────────────────────
$rgExists = az group exists --name $ResourceGroup
if ($rgExists -ne 'true') {
    throw "Resource group '$ResourceGroup' does not exist. Create it manually (and apply role assignments) before running this script."
}
Write-Host "Resource group: $ResourceGroup (exists)" -ForegroundColor Green

# ── Step 4: optional reset ──────────────────────────────────────────────────
if ($Reset) {
    Write-Host "`n-Reset specified. Deleting ALL resources in $ResourceGroup (RG preserved)..." -ForegroundColor Yellow
    & (Join-Path $infraDir 'reset.ps1') -ResourceGroup $ResourceGroup -Force
    if ($LASTEXITCODE -ne 0) { throw "Reset failed." }
}

# ── Step 5: deploy bicep ────────────────────────────────────────────────────
$bicepFile = Join-Path $infraDir 'main.bicep'
$paramFile = Join-Path $infraDir 'main.bicepparam'

$useVendorImport = $VendorAcrFqdn -and -not $SkipImageImport -and (
    $UseAad -or ($VendorAcrTokenName -and $VendorAcrTokenPassword)
)
$phase1AppImages = $useVendorImport   # phase 1 uses placeholder images so container apps deploy before images exist

# A reusable function that runs one bicep deployment with optional image overrides.
function Invoke-BicepDeployment {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$AppImageTagOverride,
        [string]$Stage2ImageTagOverride,
        [string]$ModelSourceOverride,
        [string]$WeightsTagOverride
    )
    $deploymentName = "contentshield-$Label-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $cmd = @(
        'deployment','group','create',
        '--name', $deploymentName,
        '--resource-group', $ResourceGroup,
        '--template-file', $bicepFile,
        '--parameters', $paramFile,
        '--parameters',
            "location=$Location",
            "apimPublisherEmail=$ApimPublisherEmail"
    )
    if ($NameSuffix)             { $cmd += @('--parameters', "nameSuffix=$NameSuffix") }
    if ($SkipApim)               { $cmd += @('--parameters','deployApim=false') }
    if ($SkipStage2)             { $cmd += @('--parameters','deployStage2=false') }
    if ($HfToken)                { $cmd += @('--parameters', "hfToken=$HfToken") }
    if ($AppImageTagOverride)    { $cmd += @('--parameters', "appImageTag=$AppImageTagOverride") }
    if ($Stage2ImageTagOverride) { $cmd += @('--parameters', "stage2ImageTag=$Stage2ImageTagOverride") }
    if ($ModelSourceOverride)    { $cmd += @('--parameters', "modelSource=$ModelSourceOverride") }
    if ($WeightsTagOverride)     {
        $cmd += @('--parameters', "weightsRepository=$WeightsRepository")
        $cmd += @('--parameters', "weightsTag=$WeightsTagOverride")
    }

    if ($WhatIf) {
        Write-Host "Running what-if for phase '$Label'..." -ForegroundColor Yellow
        $cmd[2] = 'what-if'
        az @cmd
        exit $LASTEXITCODE
    }

    Write-Host "`nDeploying phase '$Label'..." -ForegroundColor Green
    $cmd += @('--output','json','--only-show-errors')
    $json = az @cmd
    if ($LASTEXITCODE -ne 0) { throw "Bicep deployment '$Label' failed." }
    if ($json -is [System.Array]) { $json = $json -join "`n" }
    $i = $json.IndexOf('{')
    if ($i -gt 0) { $json = $json.Substring($i) }
    return ($json | ConvertFrom-Json)
}

# Phase 1: deploy infra. If we are going to import images from a vendor ACR,
# leave appImage/stage2Image at their bicep defaults (mcr quickstart) so the
# container apps boot to a placeholder while we sync real images.
$result = Invoke-BicepDeployment -Label 'phase1'
$out = $result.properties.outputs

# ── Step 5b: import images from vendor ACR (if credentials provided) ────────
if ($useVendorImport) {
    $targetAcr = ($out.acrLoginServer.value -split '\.')[0]
    Write-Host "`nSyncing images from vendor ACR ($VendorAcrFqdn) -> $targetAcr ..." -ForegroundColor Cyan
    & (Join-Path $infraDir 'scripts\sync-images-from-vendor.ps1') `
        -TargetAcrName $targetAcr `
        -VendorAcrFqdn $VendorAcrFqdn `
        -VendorAcrTokenName $VendorAcrTokenName `
        -VendorAcrTokenPassword $VendorAcrTokenPassword `
        -Tag $ImageTag `
        -AllTags:$AllTags `
        -EnableArtifactStreaming:$EnableArtifactStreaming `
        -UseAad:$UseAad `
        -Force
    if ($LASTEXITCODE -ne 0) { throw "Image sync failed." }

    # Phase 2: roll container apps to the freshly imported images by tag.
    # The bicep template builds the full image reference using the customer ACR
    # login server, so we only need to pass the tag.

    # ── Optionally also sync the weights OCI artifact (AAD or token). ────────
    $effectiveWeightsTag = if ($WeightsTag) { $WeightsTag } else { $ImageTag }
    $weightsSynced = $false
    if ($SyncWeights) {
        Write-Host "`nSyncing weights artifact ($WeightsRepository`:$effectiveWeightsTag) from vendor ACR -> $targetAcr ..." -ForegroundColor Cyan
        & (Join-Path $infraDir 'scripts\sync-weights-from-vendor.ps1') `
            -TargetAcrName $targetAcr `
            -VendorAcrFqdn $VendorAcrFqdn `
            -VendorAcrTokenName $VendorAcrTokenName `
            -VendorAcrTokenPassword $VendorAcrTokenPassword `
            -WeightsRepository $WeightsRepository `
            -Tag $effectiveWeightsTag `
            -UseAad:$UseAad `
            -InstallOrasIfMissing
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [warn] weights sync failed. Phase 2 will fall back to modelSource=hf-hub (HuggingFace) for the prewarm job." -ForegroundColor Yellow
            $LASTEXITCODE = 0
        } else {
            $weightsSynced = $true
        }
    }

    $phase2Args = @{
        Label = 'phase2-images'
        AppImageTagOverride = $ImageTag
        Stage2ImageTagOverride = $ImageTag
    }
    if ($weightsSynced) {
        $phase2Args['ModelSourceOverride'] = 'acr-oras'
        $phase2Args['WeightsTagOverride'] = $effectiveWeightsTag
    }
    $result = Invoke-BicepDeployment @phase2Args
    $out = $result.properties.outputs
}

# ── Step 5c: ensure ACR Artifact Streaming is enabled on both repos. ──────────
# Idempotent. Runs whether or not we just imported — covers the case where
# images were pushed directly to the customer ACR by another path (ACR Task,
# pipeline, etc.). Stage-2 is the big win: 10 GB images start streaming.
if ($EnableArtifactStreaming -and -not $WhatIf) {
    $targetAcr = ($out.acrLoginServer.value -split '\.')[0]
    foreach ($repo in @('contentshield','contentshield-stage2')) {
        Write-Host "Enabling auto artifact-streaming on $targetAcr/$repo ..." -ForegroundColor DarkGray
        az acr artifact-streaming update `
            --name $targetAcr `
            --repository $repo `
            --enable-auto-streaming True `
            --only-show-errors 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [warn] artifact-streaming update failed for $repo. (Premium ACR required; preview in some regions.)" -ForegroundColor Yellow
            $LASTEXITCODE = 0
        }
    }
}

# ── Step 5d: kick the HF cache pre-warm job (one-shot, idempotent). ────────────
# Populates the NFS hfcache share with the SLM weights so the first GPU cold
# start does not pay the 5–10 min HuggingFace download. The job is a manual
# Container Apps Job mounted on the same NFS share as stage-2. Safe to run
# every deploy — HF skips already-cached files.
$prewarmJobName = $out.hfPrewarmJobName.value
if ($PrewarmHfCache -and -not $WhatIf -and $prewarmJobName) {
    Write-Host "`nStarting HF cache pre-warm job '$prewarmJobName' ..." -ForegroundColor Cyan
    $startJson = az containerapp job start `
        --name $prewarmJobName `
        --resource-group $ResourceGroup `
        --only-show-errors -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [warn] could not start pre-warm job: $startJson" -ForegroundColor Yellow
        $LASTEXITCODE = 0
    } else {
        try {
            $execution = $startJson | ConvertFrom-Json
            $execName = $execution.name
            Write-Host "  execution: $execName" -ForegroundColor DarkGray
            if ($WaitForPrewarm) {
                Write-Host "  -WaitForPrewarm: polling until job execution completes (up to 1h)..." -ForegroundColor DarkGray
                $deadline = (Get-Date).AddMinutes(60)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 20
                    $status = az containerapp job execution show `
                        --name $prewarmJobName `
                        --resource-group $ResourceGroup `
                        --job-execution-name $execName `
                        --query "properties.status" -o tsv 2>$null
                    Write-Host "    status: $status" -ForegroundColor DarkGray
                    if ($status -in @('Succeeded','Failed','Stopped','Degraded')) { break }
                }
                if ($status -ne 'Succeeded') {
                    Write-Host "  [warn] pre-warm job ended with status '$status'. Check logs: az containerapp job execution show -n $prewarmJobName -g $ResourceGroup --job-execution-name $execName" -ForegroundColor Yellow
                } else {
                    Write-Host "  [OK] pre-warm complete." -ForegroundColor Green
                }
            } else {
                Write-Host "  Job is running in the background. Track with:" -ForegroundColor DarkGray
                Write-Host "    az containerapp job execution show -n $prewarmJobName -g $ResourceGroup --job-execution-name $execName" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [warn] could not parse job-start response (job may still be running)." -ForegroundColor Yellow
        }
    }
}

Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NAT Gateway IP:        $($out.natGatewayPublicIp.value)"
Write-Host "  ACR:                   $($out.acrLoginServer.value)"
Write-Host "  Container Apps Env:    $($out.caeName.value) (domain: $($out.caeDefaultDomain.value))"
Write-Host "  App FQDN:              $($out.appFqdn.value)"
Write-Host "  Stage 2 FQDN:          $($out.stage2Fqdn.value)"
Write-Host "  Content Safety:        $($out.contentSafetyEndpoint.value)"
Write-Host "  APIM Gateway:          $($out.apimGatewayUrl.value)"
Write-Host "  Storage Account:       $($out.storageAccountName.value)"
Write-Host "  NFS Host:              $($out.storageNfsHost.value)"
Write-Host "  NFS Share Path:        $($out.storageNfsSharePath.value)"
Write-Host "  HF Cache Mount Path:   $($out.hfCacheMountPath.value)"
Write-Host ""
Write-Host "  Managed identity principalIds (system-assigned):" -ForegroundColor Gray
Write-Host "    ACR:           $($out.acrPrincipalId.value)" -ForegroundColor Gray
Write-Host "    Content Safety:$($out.contentSafetyPrincipalId.value)" -ForegroundColor Gray
Write-Host "    App:           $($out.appPrincipalId.value)" -ForegroundColor Gray
Write-Host "    Stage 2:       $($out.stage2PrincipalId.value)" -ForegroundColor Gray
Write-Host "    APIM:          $($out.apimPrincipalId.value)" -ForegroundColor Gray
Write-Host ""
