#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Export ContentShield images from your ACR as .tar files for offline shipping to a customer.

.DESCRIPTION
  Pulls each image:tag from the source ACR using docker, then runs `docker save`
  to produce a .tar file per image under -OutDir. Customer can then load + push
  the tarballs into their own ACR using import-images.ps1 -FromTarballDir.

  Output:
    <OutDir>/contentshield_<tag>.tar
    <OutDir>/contentshield-stage2_<tag>.tar
    <OutDir>/manifest.json     <-- list of {repo, tag, file} for the customer

  Requirements on YOUR machine:
    - Docker Desktop / docker engine running
    - AcrPull on the source ACR (you already have this — you created it)
    - Enough disk space (stage2 GPU images can be 10+ GiB)

.PARAMETER SourceAcrName
  Source ACR name (not FQDN). Default: contentshieldacr.

.PARAMETER Repositories
  Repos to export. Default: contentshield, contentshield-stage2.

.PARAMETER Tag
  Specific tag, or 'latest-detected' (default) to pick newest tag in each repo.

.PARAMETER OutDir
  Output directory. Default: .\dist\images

.PARAMETER Compress
  Also produce a single .zip of OutDir for easier shipping.

.EXAMPLE
  .\export-images.ps1
  .\export-images.ps1 -Tag main-20260511-184714 -Compress
#>
[CmdletBinding()]
param(
    [string]$SourceAcrName = 'contentshieldacr',
    [string[]]$Repositories = @('contentshield','contentshield-stage2'),
    [string]$Tag = 'latest-detected',
    [string]$OutDir = '.\dist\images',
    [switch]$Compress
)

$ErrorActionPreference = 'Stop'

# Verify docker is available
$null = docker version 2>$null
if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and retry." }

$src = (az acr show -n $SourceAcrName --query "{server:loginServer}" -o json) | ConvertFrom-Json
if (-not $src) { throw "Source ACR '$SourceAcrName' not found in current subscription." }
$server = $src.server

Write-Host "Logging into $server..." -ForegroundColor Cyan
az acr login -n $SourceAcrName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az acr login failed for $SourceAcrName." }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$manifest = @()

foreach ($repo in $Repositories) {
    $importTag = $Tag
    if ($Tag -eq 'latest-detected') {
        $importTag = (az acr repository show-tags -n $SourceAcrName --repository $repo `
                        --orderby time_desc --top 1 -o tsv).Trim()
        if (-not $importTag) { Write-Host "  [skip] no tags in $repo" -ForegroundColor Yellow; continue }
    }

    $fullImage = "$server/${repo}:${importTag}"
    $safeName  = "$($repo -replace '[^a-zA-Z0-9_-]','_')_$importTag"
    $tarFile   = Join-Path $OutDir "$safeName.tar"

    Write-Host "`nPulling $fullImage ..." -ForegroundColor Cyan
    docker pull $fullImage
    if ($LASTEXITCODE -ne 0) { throw "docker pull failed for $fullImage" }

    Write-Host "Saving to $tarFile ..." -ForegroundColor Cyan
    docker save -o $tarFile $fullImage
    if ($LASTEXITCODE -ne 0) { throw "docker save failed for $fullImage" }

    $sizeMB = [math]::Round((Get-Item $tarFile).Length / 1MB, 1)
    Write-Host "  [OK] $tarFile ($sizeMB MB)" -ForegroundColor Green

    $manifest += [pscustomobject]@{
        repo      = $repo
        tag       = $importTag
        sourceImage = $fullImage
        file      = (Split-Path $tarFile -Leaf)
        sizeMB    = $sizeMB
    }
}

$manifestPath = Join-Path $OutDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding utf8
Write-Host "`nWrote manifest: $manifestPath" -ForegroundColor Green

if ($Compress) {
    $zip = "$OutDir.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path "$OutDir\*" -DestinationPath $zip
    $zipMB = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Host "Bundled: $zip ($zipMB MB)" -ForegroundColor Green
}

Write-Host "`n=== Ship these files to the customer ===" -ForegroundColor Cyan
Write-Host "Directory: $((Resolve-Path $OutDir).Path)"
Write-Host ""
Write-Host "On the customer side they run:" -ForegroundColor Yellow
Write-Host "  .\scripts\import-images.ps1 -TargetAcrName <theirAcr> -FromTarballDir <pathToImagesDir>"
