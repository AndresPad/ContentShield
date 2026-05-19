#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (CUSTOMER-side) Copy a ContentShield model-weights OCI artifact from the
  vendor ACR into the customer ACR using ORAS.

.DESCRIPTION
  Counterpart to sync-images-from-vendor.ps1 — that script uses 'az acr import'
  which is image-only. Model weights ship as an OCI artifact (artifact-type
  application/vnd.contentshield.model.v1+tar), so we use 'oras copy' instead.

  'oras copy' is server-side blob copy: bytes never traverse the pipeline
  runner. Same speed/cost as 'az acr import' for image manifests.

  Auth: the SAME mechanism as sync-images-from-vendor.ps1 — AAD for same-tenant
  Microsoft customers, scoped token for external customers. ORAS understands
  both via 'oras login' (we wire them up here).

.PARAMETER TargetAcrName
  Customer's ACR name (not FQDN).

.PARAMETER VendorAcrFqdn
  Source ACR FQDN, e.g. 'contentshieldacr.azurecr.io'.

.PARAMETER VendorAcrTokenName
  Username for the scoped token (e.g. 'pull-acme'). Required unless -UseAad.

.PARAMETER VendorAcrTokenPassword
  Password for the scoped token. Required unless -UseAad.

.PARAMETER WeightsRepository
  Repository name of the weights artifact in both ACRs. Default
  'contentshield-stage2-weights'.

.PARAMETER Tag
  Tag to copy. Default 'latest'. Convention: same semver as the runtime
  image tag.

.PARAMETER UseAad
  Use AAD/MI auth for the vendor ACR pull. Requires the current az login
  identity to have AcrPull on the vendor ACR. Intended for internal-Microsoft
  customers in the same tenant. When set, -VendorAcrTokenName /
  -VendorAcrTokenPassword may be omitted.

.PARAMETER OrasPath
  Path to the 'oras' binary. Default 'oras' (resolved from PATH). If oras is
  not on PATH, point this at the downloaded binary or set -InstallOrasIfMissing.

.PARAMETER InstallOrasIfMissing
  When oras is not on PATH, download a pinned release into the working
  directory and use it. Off by default (pipelines should install via a
  dedicated task — this is for ad-hoc runs).

.EXAMPLE
  # Internal-MS customer, AAD auth
  .\sync-weights-from-vendor.ps1 `
      -TargetAcrName    contentshieldacrxyz123 `
      -VendorAcrFqdn    contentshieldacr.azurecr.io `
      -Tag              1.4.0 `
      -UseAad

.EXAMPLE
  # External customer, scoped token (password should come from Key Vault)
  .\sync-weights-from-vendor.ps1 `
      -TargetAcrName          contentshieldacracme `
      -VendorAcrFqdn          contentshieldacr.azurecr.io `
      -VendorAcrTokenName     pull-acme `
      -VendorAcrTokenPassword (Get-Secret VendorAcrTokenAcme) `
      -Tag                    1.4.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetAcrName,
    [Parameter(Mandatory)][string]$VendorAcrFqdn,
    [string]$VendorAcrTokenName,
    [string]$VendorAcrTokenPassword,
    [string]$WeightsRepository = 'contentshield-stage2-weights',
    [string]$Tag = 'latest',
    [switch]$UseAad,
    [string]$OrasPath = 'oras',
    [switch]$InstallOrasIfMissing
)

$ErrorActionPreference = 'Stop'

if (-not $UseAad) {
    if (-not $VendorAcrTokenName -or -not $VendorAcrTokenPassword) {
        throw "Either pass -UseAad (AAD auth) OR both -VendorAcrTokenName and -VendorAcrTokenPassword (scoped-token auth)."
    }
}

# ── Resolve oras CLI ─────────────────────────────────────────────────────────
$orasCmd = Get-Command $OrasPath -ErrorAction SilentlyContinue
if (-not $orasCmd -and $InstallOrasIfMissing) {
    Write-Host "oras not on PATH — installing pinned release locally..." -ForegroundColor Yellow
    $orasVersion = '1.2.3'
    $isWindows = $PSVersionTable.Platform -ne 'Unix' -and $env:OS -like 'Windows*'
    if ($isWindows) {
        $url = "https://github.com/oras-project/oras/releases/download/v${orasVersion}/oras_${orasVersion}_windows_amd64.zip"
        $archive = Join-Path $PWD 'oras.zip'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        Expand-Archive -Path $archive -DestinationPath (Join-Path $PWD 'oras-bin') -Force
        $OrasPath = (Join-Path $PWD 'oras-bin/oras.exe')
    } else {
        $url = "https://github.com/oras-project/oras/releases/download/v${orasVersion}/oras_${orasVersion}_linux_amd64.tar.gz"
        $archive = Join-Path $PWD 'oras.tgz'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        tar -xzf $archive -C $PWD oras
        $OrasPath = (Join-Path $PWD 'oras')
        & chmod +x $OrasPath
    }
    $orasCmd = Get-Command $OrasPath -ErrorAction SilentlyContinue
}
if (-not $orasCmd) {
    throw @"
'oras' CLI is required but not found.
Either:
  - Install oras and re-run (https://oras.land/docs/installation), or
  - Re-run with -InstallOrasIfMissing to download a pinned release into the working dir, or
  - Pass -OrasPath <full path to the binary>.
"@
}
$orasBin = $orasCmd.Source
$orasVer = (& $orasBin version 2>$null | Select-String -Pattern '^Version:' | Select-Object -First 1).ToString().Trim()
Write-Host "oras: $orasBin ($orasVer)" -ForegroundColor Gray

# ── Validate az context + target ACR ─────────────────────────────────────────
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged into Azure CLI. Run 'az login'." }
$targetAcr = az acr show -n $TargetAcrName -o json 2>$null | ConvertFrom-Json
if (-not $targetAcr) { throw "Target ACR '$TargetAcrName' not found in current subscription ($($account.id))." }
$targetFqdn = $targetAcr.loginServer
Write-Host "Target ACR: $targetFqdn" -ForegroundColor Green
Write-Host "Vendor ACR: $VendorAcrFqdn" -ForegroundColor Green

# ── Login oras into the VENDOR ACR ───────────────────────────────────────────
Write-Host "`nLogging oras into vendor ACR ($VendorAcrFqdn)..." -ForegroundColor Cyan
if ($UseAad) {
    # Pull a data-plane token from AAD for the vendor ACR resource.
    $vendorAcrName = ($VendorAcrFqdn -split '\.')[0]
    $aadToken = az acr login --name $vendorAcrName --expose-token --output tsv --query accessToken 2>$null
    if (-not $aadToken) { throw "Failed to acquire AAD ACR token for $VendorAcrFqdn (does the current identity have AcrPull?)." }
    $aadToken | & $orasBin login $VendorAcrFqdn -u '00000000-0000-0000-0000-000000000000' --password-stdin
} else {
    $VendorAcrTokenPassword | & $orasBin login $VendorAcrFqdn -u $VendorAcrTokenName --password-stdin
}
if ($LASTEXITCODE -ne 0) { throw "oras login to vendor ACR failed." }

# ── Login oras into the TARGET (customer) ACR via AAD ────────────────────────
# The deploy identity always has AcrPush on the customer ACR.
Write-Host "Logging oras into target ACR ($targetFqdn)..." -ForegroundColor Cyan
$targetToken = az acr login --name $TargetAcrName --expose-token --output tsv --query accessToken 2>$null
if (-not $targetToken) { throw "Failed to acquire AAD ACR token for $TargetAcrName." }
$targetToken | & $orasBin login $targetFqdn -u '00000000-0000-0000-0000-000000000000' --password-stdin
if ($LASTEXITCODE -ne 0) { throw "oras login to target ACR failed." }

# ── Pre-flight: does the source tag exist? ───────────────────────────────────
$sourceRef = "$VendorAcrFqdn/${WeightsRepository}:${Tag}"
$destRef   = "$targetFqdn/${WeightsRepository}:${Tag}"

Write-Host "`nResolving source manifest $sourceRef ..." -ForegroundColor Cyan
& $orasBin manifest fetch $sourceRef --descriptor | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Source artifact $sourceRef not found (or pull permission missing)."
}

# ── Server-side copy ─────────────────────────────────────────────────────────
Write-Host "`nCopying $sourceRef -> $destRef ..." -ForegroundColor Cyan
& $orasBin copy --recursive $sourceRef $destRef
if ($LASTEXITCODE -ne 0) { throw "oras copy failed." }

# ── Resolve destination digest for the summary ───────────────────────────────
$destDigest = az acr repository show -n $TargetAcrName --image "${WeightsRepository}:${Tag}" --query digest -o tsv 2>$null

Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Weights artifact synced" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host "  Source:  $sourceRef"
Write-Host "  Target:  $destRef"
if ($destDigest) { Write-Host "  Digest:  $destDigest" }
Write-Host ""
