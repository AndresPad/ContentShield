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

    # ── Stage-2 backend selection (ICM handoff switch) ────────────────────
    #   slm-gpu  : GPU vLLM (Gemma) only        (needs A100 quota)
    #   aoai-cpu : Azure OpenAI gpt-4o only      (no GPU)
    #   both     : deploy both (our demo RG)
    #   none     : skip Stage-2
    [ValidateSet('slm-gpu','aoai-cpu','both','none')]
    [string]$Stage2Mode = 'both',

    # Vendor ACR to import the ContentShield images from (same-tenant, AAD auth).
    [string]$VendorAcr = 'ratioaidev.azurecr.io',
    [string]$AppImageTag = '1.0.2',
    [string]$SlmGpuStage2ImageTag = '1.0.3-dev.20260714b-slm-gpu',
    [string]$AoaiCpuStage2ImageTag = '1.0.3-dev.20260715-sdk-retry-aoai-cpu',

    # Azure OpenAI account backing the aoai-cpu Stage-2. The ResourceId is used
    # to grant the app managed identity 'Cognitive Services OpenAI User' (works
    # cross-resource-group). Pass -AzureOpenAiApiKey instead to use key auth
    # (which skips the RBAC grant).
    [string]$AzureOpenAiResourceId = '/subscriptions/01819f01-7af1-4dd8-9354-9dccc163ceae/resourceGroups/rg-ratio-ai-dev/providers/Microsoft.CognitiveServices/accounts/RatioAIFoundryCentralUS',
    [string]$AzureOpenAiApiKey = '',

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
        -CheckGpuQuota:(($Stage2Mode -in @('slm-gpu','both')) -and -not $SkipStage2)
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

$doImport = -not $SkipImageImport

# Import one repo:tag from the vendor ACR into the customer ACR, server-side
# (blob-to-blob inside Azure) using the caller's AAD identity. Both registries
# are in the same tenant, so no scoped token is required.
function Import-ContentShieldImage {
    param(
        [Parameter(Mandatory)][string]$TargetAcr,
        [Parameter(Mandatory)][string]$VendorAcr,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag
    )
    if ($WhatIf) {
        Write-Host "  [what-if] import $VendorAcr/${Repo}:${Tag} -> $TargetAcr" -ForegroundColor DarkGray
        return
    }
    Write-Host "  $VendorAcr/${Repo}:${Tag} -> $TargetAcr.azurecr.io/${Repo}:${Tag}" -ForegroundColor Gray
    az acr import --name $TargetAcr --source "$VendorAcr/${Repo}:${Tag}" --image "${Repo}:${Tag}" --force --only-show-errors 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Image import failed for ${Repo}:${Tag} from $VendorAcr" }
}

# A reusable function that runs one bicep deployment.
function Invoke-BicepDeployment {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Stage2ModeOverride,
        [switch]$PlaceholderImages
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
    $mode = if ($Stage2ModeOverride) { $Stage2ModeOverride } else { $Stage2Mode }
    $cmd += @('--parameters', "stage2Mode=$mode")
    if ($NameSuffix)        { $cmd += @('--parameters', "nameSuffix=$NameSuffix") }
    if ($SkipApim)          { $cmd += @('--parameters','deployApim=false') }
    if ($SkipStage2)        { $cmd += @('--parameters','deployStage2=false') }
    if ($HfToken)           { $cmd += @('--parameters', "hfToken=$HfToken") }
    if ($AzureOpenAiApiKey) { $cmd += @('--parameters', "azureOpenAiApiKey=$AzureOpenAiApiKey") }
    if ($PlaceholderImages) {
        # Phase 1: blank tags so container apps run the mcr placeholder while we import.
        $cmd += @('--parameters','appImageTag=','slmGpuStage2ImageTag=','aoaiCpuStage2ImageTag=')
    } else {
        $cmd += @('--parameters',
            "appImageTag=$AppImageTag",
            "slmGpuStage2ImageTag=$SlmGpuStage2ImageTag",
            "aoaiCpuStage2ImageTag=$AoaiCpuStage2ImageTag")
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

# Phase 1: deploy infra. When importing, leave images at their placeholder and
# keep Stage-2 OFF so the deploy never tries to pull tags the fresh ACR does not
# have yet (and does not spin up a GPU node before the baked slm image exists).
if ($doImport) {
    $result = Invoke-BicepDeployment -Label 'phase1-infra' -Stage2ModeOverride 'none' -PlaceholderImages
} else {
    $result = Invoke-BicepDeployment -Label 'phase1'
}
$out = $result.properties.outputs
$targetAcr = ($out.acrLoginServer.value -split '\.')[0]

# ── Step 5b: import the selected images from the vendor ACR (server-side, AAD) ─
if ($doImport) {
    Write-Host "`nImporting ContentShield images from $VendorAcr -> $targetAcr ..." -ForegroundColor Cyan
    Import-ContentShieldImage -TargetAcr $targetAcr -VendorAcr $VendorAcr -Repo 'contentshield' -Tag $AppImageTag
    if ($Stage2Mode -in @('slm-gpu','both')) {
        Import-ContentShieldImage -TargetAcr $targetAcr -VendorAcr $VendorAcr -Repo 'contentshield-stage2' -Tag $SlmGpuStage2ImageTag
    }
    if ($Stage2Mode -in @('aoai-cpu','both')) {
        Import-ContentShieldImage -TargetAcr $targetAcr -VendorAcr $VendorAcr -Repo 'contentshield-stage2' -Tag $AoaiCpuStage2ImageTag
    }

    # Phase 2: roll to the real Stage-2 mode + imported image tags.
    if (-not $WhatIf) {
        $result = Invoke-BicepDeployment -Label 'phase2-apps'
        $out = $result.properties.outputs
    }
}

# ── Step 5b2: grant the aoai-cpu Stage-2 MI access to Azure OpenAI ──────────
# The wrapper uses DefaultAzureCredential when no API key is set, so its system
# managed identity needs 'Cognitive Services OpenAI User' on the target account.
# Works cross-resource-group (e.g. an AOAI/Foundry account in another RG).
if (($Stage2Mode -in @('aoai-cpu','both')) -and $AzureOpenAiResourceId -and -not $AzureOpenAiApiKey -and -not $WhatIf) {
    $aoaiMi = $out.stage2AoaiPrincipalId.value
    if ($aoaiMi) {
        Write-Host "`nGranting aoai Stage-2 MI 'Cognitive Services OpenAI User' on Azure OpenAI ..." -ForegroundColor Cyan
        az role assignment create `
            --assignee-object-id $aoaiMi `
            --assignee-principal-type ServicePrincipal `
            --role 'Cognitive Services OpenAI User' `
            --scope $AzureOpenAiResourceId `
            --only-show-errors 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [warn] RBAC grant failed. Grant manually or pass -AzureOpenAiApiKey." -ForegroundColor Yellow
            Write-Host "         scope=$AzureOpenAiResourceId principal=$aoaiMi" -ForegroundColor Yellow
            $LASTEXITCODE = 0
        } else {
            Write-Host "  [OK] role granted." -ForegroundColor Green
        }
    }
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
            --enable-streaming True `
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
Write-Host "  Stage-2 mode:          $($out.stage2Mode.value)"
Write-Host "  Orchestrator routes -> $($out.orchestratorStage2TargetApp.value)"
Write-Host "  Stage-2 SLM-GPU FQDN:  $($out.stage2SlmFqdn.value)"
Write-Host "  Stage-2 AOAI-CPU FQDN: $($out.stage2AoaiFqdn.value)"
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
Write-Host "    Stage2 SLM:    $($out.stage2SlmPrincipalId.value)" -ForegroundColor Gray
Write-Host "    Stage2 AOAI:   $($out.stage2AoaiPrincipalId.value)" -ForegroundColor Gray
Write-Host "    APIM:          $($out.apimPrincipalId.value)" -ForegroundColor Gray
Write-Host ""
