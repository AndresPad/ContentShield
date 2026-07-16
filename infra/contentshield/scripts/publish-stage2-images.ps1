#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build and publish one or both production Stage2 image variants.

.DESCRIPTION
  Publishes variant-specific immutable tags in the contentshield-stage2 repository:
    <version>-slm-gpu   — baked Gemma model served by vLLM on GPU
    <version>-aoai-cpu  — CPU adapter for GPT-4o hosted on Azure OpenAI

  The script delegates each server-side ACR Task build to publish-image.ps1 so
  tag collision checks, optional signing, digest reporting, and tag locking stay
  consistent with other ContentShield releases.

.EXAMPLE
  .\publish-stage2-images.ps1 -VendorAcrName ratioai -Version 1.0.3

.EXAMPLE
  .\publish-stage2-images.ps1 -VendorAcrName ratioai -Version 1.0.3 `
      -Variant aoai-cpu
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VendorAcrName,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('all', 'aoai-cpu', 'slm-gpu')][string]$Variant = 'all',
    [string]$ContextPath,
    [ValidateRange(300, 21600)][int]$BuildTimeoutSeconds = 14400,
    [bool]$LockTag = $true,
    [switch]$Sign
)

$ErrorActionPreference = 'Stop'

if (-not $ContextPath) {
    $ContextPath = Join-Path $PSScriptRoot '..\..\..\RatioAI.ContentShield\services\stage2'
}
$ContextPath = (Resolve-Path $ContextPath).Path
$publishScript = Join-Path $PSScriptRoot 'publish-image.ps1'

$variants = @(
    @{
        Name = 'aoai-cpu'
        Dockerfile = 'Dockerfile.aoai-cpu'
    },
    @{
        Name = 'slm-gpu'
        Dockerfile = 'Dockerfile.slm-gpu'
    }
)
  if ($Variant -ne 'all') {
    $variants = @($variants | Where-Object { $_.Name -eq $Variant })
  }

  Write-Host "Publishing ContentShield Stage2 $Version ($Variant) from $ContextPath" -ForegroundColor Cyan

foreach ($variant in $variants) {
    $tag = "$Version-$($variant.Name)"
    Write-Host "`n--- $($variant.Name): contentshield-stage2:$tag ---" -ForegroundColor Cyan
    & $publishScript `
        -VendorAcrName $VendorAcrName `
        -Repository 'contentshield-stage2' `
        -Version $tag `
        -Dockerfile $variant.Dockerfile `
        -ContextPath $ContextPath `
        -BuildTimeoutSeconds $BuildTimeoutSeconds `
        -LockTag:$LockTag `
        -Sign:$Sign
}

Write-Host "`nPublished Stage2 image(s):" -ForegroundColor Green
foreach ($variant in $variants) {
  Write-Host "  contentshield-stage2:$Version-$($variant.Name)"
}
