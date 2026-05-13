#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Copy ContentShield container images from a source ACR into the newly-deployed ACR.

.DESCRIPTION
  Uses `az acr import` to perform a server-side copy of each repository:tag from
  the source ACR into the target ACR. No local docker pull/push is required.

  Default behaviour: imports the most recent tag of each repo, AND re-tags it
  as `latest` in the target so the Container Apps can pull `:latest`.

  Cross-subscription / cross-tenant: pass -SourceSubscription and ensure your
  identity has AcrPull on the source and AcrPush on the target.

.PARAMETER SourceAcrName
  Source ACR (just the name, not the FQDN). Default: contentshieldacr.

.PARAMETER TargetAcrName
  Target ACR (just the name). Default: contentshieldacricm.

.PARAMETER SourceSubscription
  Subscription containing the source ACR (only needed if different from the
  current az context).

.PARAMETER Repositories
  Repos to copy. Default: contentshield, contentshield-stage2.

.PARAMETER Tag
  Specific tag to import. Default: 'latest-detected' which picks the newest
  tag in each source repo by push time.

.PARAMETER AlsoTagLatest
  After import, also tag the imported image as ':latest' in the target.
  Defaults to $true so the bicep deployment's :latest image references work.

.PARAMETER Force
  Pass --force to `az acr import` (overwrite existing target tags).

.EXAMPLE
  # Most common: copy latest of each repo into the new ACR
  .\import-images.ps1 -TargetAcrName contentshieldacricm

.EXAMPLE
  # Copy a specific tag
  .\import-images.ps1 -TargetAcrName contentshieldacricm -Tag main-20260511-184714

.EXAMPLE
  # Across subscriptions
  .\import-images.ps1 `
      -SourceAcrName contentshieldacr `
      -SourceSubscription "01819f01-7af1-4dd8-9354-9dccc163ceae" `
      -TargetAcrName contentshieldacricm
#>
[CmdletBinding(DefaultParameterSetName='FromAcr')]
param(
    [Parameter(ParameterSetName='FromAcr')]
    [string]$SourceAcrName = 'contentshieldacr',
    [Parameter(Mandatory)][string]$TargetAcrName,
    [Parameter(ParameterSetName='FromAcr')]
    [string]$SourceSubscription,
    [string[]]$Repositories = @('contentshield','contentshield-stage2'),
    [Parameter(ParameterSetName='FromAcr')]
    [string]$Tag = 'latest-detected',
    [bool]$AlsoTagLatest = $true,
    [switch]$Force,

    # Customer-side: load images from tarballs (produced by export-images.ps1)
    [Parameter(Mandatory, ParameterSetName='FromTarballs')]
    [string]$FromTarballDir
)

$ErrorActionPreference = 'Stop'

# ── Customer-side flow: load .tar files + push to target ACR ────────────────
if ($PSCmdlet.ParameterSetName -eq 'FromTarballs') {
    if (-not (Test-Path $FromTarballDir)) { throw "FromTarballDir '$FromTarballDir' not found." }
    $null = docker version 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and retry." }

    $tgt = (az acr show -n $TargetAcrName --query "{id:id, server:loginServer}" -o json) | ConvertFrom-Json
    if (-not $tgt) { throw "Target ACR '$TargetAcrName' not found in current subscription." }
    Write-Host "Target: $($tgt.server)" -ForegroundColor Green

    Write-Host "Logging into target ACR..." -ForegroundColor Cyan
    az acr login -n $TargetAcrName | Out-Null

    $manifestPath = Join-Path $FromTarballDir 'manifest.json'
    if (-not (Test-Path $manifestPath)) { throw "manifest.json not found in $FromTarballDir." }
    $items = Get-Content $manifestPath -Raw | ConvertFrom-Json

    foreach ($item in $items) {
        $tarPath = Join-Path $FromTarballDir $item.file
        if (-not (Test-Path $tarPath)) { Write-Host "  [skip] missing $tarPath" -ForegroundColor Yellow; continue }

        Write-Host "`nLoading $($item.file) ..." -ForegroundColor Cyan
        docker load -i $tarPath
        if ($LASTEXITCODE -ne 0) { throw "docker load failed for $tarPath" }

        # Re-tag source -> target/<repo>:<tag>
        $targetTagged = "$($tgt.server)/$($item.repo):$($item.tag)"
        docker tag $item.sourceImage $targetTagged
        if ($LASTEXITCODE -ne 0) { throw "docker tag failed for $($item.sourceImage)" }
        Write-Host "Pushing $targetTagged ..." -ForegroundColor Cyan
        docker push $targetTagged
        if ($LASTEXITCODE -ne 0) { throw "docker push failed for $targetTagged" }

        if ($AlsoTagLatest) {
            $latest = "$($tgt.server)/$($item.repo):latest"
            docker tag $item.sourceImage $latest
            docker push $latest
            Write-Host "  [OK] also tagged $latest" -ForegroundColor Green
        }
    }

    Write-Host "`n=== Done ===" -ForegroundColor Green
    Write-Host "Now update infra\contentshield\main.bicepparam with:" -ForegroundColor Yellow
    Write-Host "  param appImage    = '$($tgt.server)/contentshield:latest'"
    Write-Host "  param stage2Image = '$($tgt.server)/contentshield-stage2:latest'"
    Write-Host "Then re-run .\deploy.ps1." -ForegroundColor Yellow
    return
}

# ── Default flow: ACR-to-ACR server-side import ─────────────────────────────
# Resolve source ACR resource id (needed by `az acr import --source`)
Write-Host "Resolving source ACR '$SourceAcrName'..." -ForegroundColor Cyan
$showArgs = @('acr','show','-n',$SourceAcrName,'--query','{id:id, server:loginServer}','-o','json')
if ($SourceSubscription) { $showArgs += @('--subscription',$SourceSubscription) }
$src = (az @showArgs) | ConvertFrom-Json
if (-not $src) { throw "Source ACR '$SourceAcrName' not found." }
Write-Host "  $($src.server)" -ForegroundColor Green

# Verify target exists
Write-Host "Resolving target ACR '$TargetAcrName'..." -ForegroundColor Cyan
$tgt = (az acr show -n $TargetAcrName --query "{id:id, server:loginServer}" -o json) | ConvertFrom-Json
if (-not $tgt) { throw "Target ACR '$TargetAcrName' not found." }
Write-Host "  $($tgt.server)" -ForegroundColor Green

foreach ($repo in $Repositories) {
    # Pick tag to import
    $importTag = $Tag
    if ($Tag -eq 'latest-detected') {
        $tagsArgs = @('acr','repository','show-tags','-n',$SourceAcrName,'--repository',$repo,'--orderby','time_desc','--top','1','-o','tsv')
        if ($SourceSubscription) { $tagsArgs += @('--subscription',$SourceSubscription) }
        $importTag = (az @tagsArgs).Trim()
        if (-not $importTag) {
            Write-Host "  [skip] No tags found in source repo '$repo'" -ForegroundColor Yellow
            continue
        }
    }

    $sourceImage = "${repo}:${importTag}"
    Write-Host "`nImporting $($src.server)/$sourceImage  -->  $($tgt.server)/$sourceImage" -ForegroundColor Cyan

    $importArgs = @(
        'acr','import',
        '-n',$TargetAcrName,
        '--source',"$($src.server)/$sourceImage",
        '--registry',$src.id,
        '--image',$sourceImage
    )
    if ($AlsoTagLatest) {
        $importArgs += @('--image',"${repo}:latest")
    }
    if ($Force) { $importArgs += '--force' }
    az @importArgs
    if ($LASTEXITCODE -ne 0) { throw "Import failed for $sourceImage" }
    Write-Host "  [OK] Imported $sourceImage" -ForegroundColor Green
    if ($AlsoTagLatest) { Write-Host "  [OK] Also tagged as ${repo}:latest" -ForegroundColor Green }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Now update infra\contentshield\main.bicepparam with:" -ForegroundColor Yellow
Write-Host "  param appImage    = '$($tgt.server)/contentshield:latest'"
Write-Host "  param stage2Image = '$($tgt.server)/contentshield-stage2:latest'"
Write-Host "Then re-run .\deploy.ps1 to push the new images into the container apps." -ForegroundColor Yellow
