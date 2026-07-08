#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (VENDOR-side) Build, push, lock, and (optionally) sign a ContentShield image
  to the central vendor ACR using ACR Tasks — no local docker required.

.DESCRIPTION
  Standardizes the per-release ritual:
    1. az acr build       — server-side build of the requested Dockerfile,
                            tagged with the given semver
    2. tag immutability   — locks the tag so it can never be overwritten
                            (write-enabled=false, delete-enabled=false)
    3. (optional) cosign  — signs the tag's manifest digest
    4. summary            — prints the digest and a "for your release notes"
                            blob you can paste to customers

  Run from anywhere with az login + acrpush on the vendor ACR. The build context
  is streamed from the supplied path to the ACR — your laptop never tar-balls
  a 10 GB image.

.PARAMETER VendorAcrName
  Vendor ACR name (NOT FQDN), e.g. contentshieldacr.

.PARAMETER Repository
  Repository in the vendor ACR. One of:
    contentshield
    contentshield-stage2

.PARAMETER Version
  Semver tag for this release, e.g. 1.4.0. NEVER reuse a version.

.PARAMETER Dockerfile
  Path to the Dockerfile relative to -ContextPath.

.PARAMETER ContextPath
  Build context (directory passed to ACR Tasks). Defaults to current directory.

.PARAMETER Platform
  Image platform, default 'linux/amd64'. GPU images must be amd64.

.PARAMETER MoveLatest
  Also re-tag :latest -> this digest. Default $false; ':latest' should only
  move in dev. Production deploys pin semver, never :latest.

.PARAMETER LockTag
  Mark the resulting tag immutable (write-enabled=false). Default $true.

.PARAMETER Sign
  Sign the resulting manifest with cosign (requires cosign in PATH and
  COSIGN_KEY / COSIGN_PASSWORD env vars, or COSIGN_EXPERIMENTAL=1 for keyless).
  Default $false.

.EXAMPLE
  # Stage-2 GPU image
  .\publish-image.ps1 -VendorAcrName contentshieldacr `
                      -Repository contentshield-stage2 `
                      -Version 1.4.0 `
                      -Dockerfile Dockerfile.stage2 `
                      -ContextPath ../../RatioAI.ContentShield/services/stage2

.EXAMPLE
  # Main app, also move :latest in dev
  .\publish-image.ps1 -VendorAcrName contentshieldacr `
                      -Repository contentshield `
                      -Version 1.4.0-dev `
                      -Dockerfile Dockerfile `
                      -ContextPath ../../RatioAI.ContentShield `
                      -MoveLatest -LockTag:$false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VendorAcrName,
    [Parameter(Mandatory)][ValidateSet('contentshield','contentshield-stage2')]
        [string]$Repository,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Dockerfile,
    [string]$ContextPath = '.',
    [string]$Platform = 'linux/amd64',
    [switch]$MoveLatest,
    [bool]$LockTag = $true,
    [switch]$Sign
)

$ErrorActionPreference = 'Stop'

# ── Validate semver-ish ──────────────────────────────────────────────────────
if ($Version -notmatch '^\d+\.\d+\.\d+([-+][\w\.]+)?$') {
    Write-Warning "Version '$Version' does not look like semver (MAJOR.MINOR.PATCH[-pre]). Continuing anyway."
}

# ── Validate az context + ACR ────────────────────────────────────────────────
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged into Azure CLI. Run 'az login'." }
$acr = az acr show -n $VendorAcrName -o json 2>$null | ConvertFrom-Json
if (-not $acr) { throw "Vendor ACR '$VendorAcrName' not found in current subscription ($($account.id))." }
Write-Host "Vendor ACR: $($acr.loginServer)" -ForegroundColor Green

# ── Check that this tag does not already exist (immutability guard) ──────────
$existing = az acr repository show-tags -n $VendorAcrName --repository $Repository --query "[?@=='$Version']" -o tsv 2>$null
if ($existing) {
    throw "Tag '${Repository}:${Version}' already exists in $VendorAcrName. Bump the version — never overwrite a published tag."
}

# ── ACR Task build (server-side, streams context, no local docker needed) ───
$imageRef = "${Repository}:${Version}"
$extraTags = @()
if ($MoveLatest) { $extraTags += "${Repository}:latest" }

Write-Host "`nBuilding $($acr.loginServer)/$imageRef from $ContextPath/$Dockerfile ..." -ForegroundColor Cyan

$buildArgs = @(
    'acr','build',
    '-r', $VendorAcrName,
    '-t', $imageRef,
    '-f', $Dockerfile,
    '--platform', $Platform
)
foreach ($t in $extraTags) { $buildArgs += @('-t', $t) }
$buildArgs += @('--only-show-errors', $ContextPath)

az @buildArgs
if ($LASTEXITCODE -ne 0) { throw "az acr build failed." }
Write-Host "[OK] build complete" -ForegroundColor Green

# ── Resolve digest of the new manifest ───────────────────────────────────────
$digest = az acr repository show -n $VendorAcrName --image $imageRef --query digest -o tsv
if (-not $digest) { throw "Could not resolve digest for $imageRef." }
Write-Host "Manifest digest: $digest" -ForegroundColor Gray

# ── Lock the tag immutable ──────────────────────────────────────────────────
if ($LockTag) {
    Write-Host "`nLocking tag '$imageRef' (write-enabled=false, delete-enabled=false)..." -ForegroundColor Cyan
    az acr repository update `
        --name $VendorAcrName `
        --image $imageRef `
        --write-enabled false `
        --delete-enabled false `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to lock tag $imageRef." }
    Write-Host "[OK] tag locked" -ForegroundColor Green
}

# ── Optional cosign signature ───────────────────────────────────────────────
if ($Sign) {
    $cosign = Get-Command cosign -ErrorAction SilentlyContinue
    if (-not $cosign) { throw "Sign requested but 'cosign' is not in PATH." }
    $fullRef = "$($acr.loginServer)/${Repository}@${digest}"
    Write-Host "`nSigning $fullRef ..." -ForegroundColor Cyan
    & cosign sign --yes $fullRef
    if ($LASTEXITCODE -ne 0) { throw "cosign sign failed." }
    Write-Host "[OK] signed" -ForegroundColor Green
}

# ── Summary block — paste into release notes / customer hand-off ────────────
Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Published ${imageRef}" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Registry:   $($acr.loginServer)"
Write-Host "  Image:      ${Repository}:${Version}"
Write-Host "  Digest:     $digest"
if ($MoveLatest) { Write-Host "  Also tagged: :latest" -ForegroundColor Yellow }
if ($LockTag)    { Write-Host "  Tag locked: yes (immutable)" }
if ($Sign)       { Write-Host "  Signed:     cosign" }
Write-Host ""
Write-Host "  Customer pipeline parameters:" -ForegroundColor Gray
Write-Host "    imageTag = $Version"
Write-Host "    vendorAcrFqdn = $($acr.loginServer)"
Write-Host ""
