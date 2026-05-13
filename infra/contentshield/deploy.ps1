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

    [switch]$Reset,
    [switch]$SkipApim,
    [switch]$SkipStage2,
    [switch]$SkipPreflight,
    [switch]$SkipImageImport,
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

$useVendorImport = $VendorAcrFqdn -and $VendorAcrTokenName -and $VendorAcrTokenPassword -and -not $SkipImageImport
$phase1AppImages = $useVendorImport   # phase 1 uses placeholder images so container apps deploy before images exist

# A reusable function that runs one bicep deployment with optional image overrides.
function Invoke-BicepDeployment {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$AppImageOverride,
        [string]$Stage2ImageOverride
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
    if ($NameSuffix)         { $cmd += @('--parameters', "nameSuffix=$NameSuffix") }
    if ($SkipApim)           { $cmd += @('--parameters','deployApim=false') }
    if ($SkipStage2)         { $cmd += @('--parameters','deployStage2=false') }
    if ($HfToken)            { $cmd += @('--parameters', "hfToken=$HfToken") }
    if ($AppImageOverride)   { $cmd += @('--parameters', "appImage=$AppImageOverride") }
    if ($Stage2ImageOverride){ $cmd += @('--parameters', "stage2Image=$Stage2ImageOverride") }

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
        -Force
    if ($LASTEXITCODE -ne 0) { throw "Image sync failed." }

    # Phase 2: roll container apps to the freshly imported images.
    $appImage    = "$($out.acrLoginServer.value)/contentshield:$ImageTag"
    $stage2Image = "$($out.acrLoginServer.value)/contentshield-stage2:$ImageTag"
    $result = Invoke-BicepDeployment -Label 'phase2-images' `
        -AppImageOverride $appImage `
        -Stage2ImageOverride $stage2Image
    $out = $result.properties.outputs
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
