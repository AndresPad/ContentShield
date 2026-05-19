#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (VENDOR-side) Publish a model-weights tarball as an OCI artifact to the
  vendor ACR using ORAS, then lock the tag.

.DESCRIPTION
  Per-model-version ritual, the analogue of publish-image.ps1 but for the
  model weights blob:

    1. oras push          — uploads the tarball as an OCI artifact under
                            <repo>:<version> with our custom artifact-type
    2. (optional) attach  — ORAS-attaches the same tarball as a referrer of
                            the matching runtime image (so 'oras copy -r'
                            promotes image + weights together)
    3. tag immutability   — locks the tag (write-enabled=false, delete-enabled=false)
    4. summary            — prints the digest and "for your release notes" blob

  Run from anywhere with az login + acrpush on the vendor ACR. Requires the
  'oras' CLI (https://oras.land) — the script bails with a clear error if
  it is not on PATH.

  The tarball you hand to -WeightsTarPath must be the HuggingFace cache
  layout (i.e. the contents of $HF_HOME/models--<org>--<name>/...) compressed
  as .tar.gz (or .tar.zst — anything you can untar on the customer side).
  Build it once locally, point this script at it, and from then on it is
  pinned by digest in the vendor ACR.

.PARAMETER VendorAcrName
  Vendor ACR name (NOT FQDN), e.g. contentshieldacr.

.PARAMETER Repository
  Repository for the weights artifact. Defaults to 'contentshield-stage2-weights'.
  Use a distinct repo from the runtime image so weights and code are versioned
  independently in the registry's UI.

.PARAMETER Version
  Semver tag for these weights, e.g. 1.4.0. NEVER reuse a version. Convention:
  match the runtime image tag so customers can deploy them as a pair.

.PARAMETER WeightsTarPath
  Path to the prepared tarball (.tar.gz / .tar.zst / .tar).

.PARAMETER ArtifactType
  OCI artifact-type media-type. Default 'application/vnd.contentshield.model.v1+tar'.
  Pick a stable string — clients filter on this to find weights vs. other artifacts.

.PARAMETER LayerMediaType
  Media-type for the single blob layer inside the artifact. Default
  'application/vnd.contentshield.model.v1.layer+gzip'. Switch to '+zstd' if
  your tarball is zstd-compressed.

.PARAMETER AttachToImage
  Also publish the artifact as an ORAS *referrer* of the matching runtime
  image (vendor ACR :<Version> in the stage-2 image repo). Lets customers
  use 'oras copy -r' to promote image + weights atomically.

.PARAMETER ImageRepository
  Repository of the runtime image when -AttachToImage is set. Default
  'contentshield-stage2'.

.PARAMETER LockTag
  Mark the resulting weights tag immutable. Default $true.

.EXAMPLE
  .\publish-weights.ps1 -VendorAcrName contentshieldacr `
                        -Version 1.4.0 `
                        -WeightsTarPath C:\dist\gemma-4-31b-it.tar.gz `
                        -AttachToImage

.EXAMPLE
  # Zstd-compressed tarball, no referrer attachment (sibling repo only)
  .\publish-weights.ps1 -VendorAcrName contentshieldacr `
                        -Version 1.4.0 `
                        -WeightsTarPath D:\dist\weights.tar.zst `
                        -LayerMediaType application/vnd.contentshield.model.v1.layer+zstd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VendorAcrName,
    [string]$Repository = 'contentshield-stage2-weights',
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$WeightsTarPath,
    [string]$ArtifactType = 'application/vnd.contentshield.model.v1+tar',
    [string]$LayerMediaType = 'application/vnd.contentshield.model.v1.layer+gzip',
    [switch]$AttachToImage,
    [string]$ImageRepository = 'contentshield-stage2',
    [bool]$LockTag = $true
)

$ErrorActionPreference = 'Stop'

# ── Validate semver-ish ──────────────────────────────────────────────────────
if ($Version -notmatch '^\d+\.\d+\.\d+([-+][\w\.]+)?$') {
    Write-Warning "Version '$Version' does not look like semver (MAJOR.MINOR.PATCH[-pre]). Continuing anyway."
}

# ── Validate tarball exists ──────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $WeightsTarPath -PathType Leaf)) {
    throw "WeightsTarPath '$WeightsTarPath' does not exist or is not a file."
}
$tarItem = Get-Item -LiteralPath $WeightsTarPath
$tarSizeGiB = [math]::Round($tarItem.Length / 1GB, 2)
$tarFileName = $tarItem.Name
Write-Host "Weights tarball: $($tarItem.FullName) ($tarSizeGiB GiB)" -ForegroundColor Gray

# ── Validate oras CLI is present ─────────────────────────────────────────────
$oras = Get-Command oras -ErrorAction SilentlyContinue
if (-not $oras) {
    throw @"
'oras' CLI is required but not found on PATH.
Install from https://oras.land/docs/installation, e.g.:
  winget install ORAS.ORAS
  # or download the release binary and add to PATH
"@
}
$orasVersion = (& oras version 2>$null | Select-String -Pattern '^Version:' | Select-Object -First 1).ToString().Trim()
Write-Host "oras: $orasVersion" -ForegroundColor Gray

# ── Validate az context + ACR ────────────────────────────────────────────────
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged into Azure CLI. Run 'az login'." }
$acr = az acr show -n $VendorAcrName -o json 2>$null | ConvertFrom-Json
if (-not $acr) { throw "Vendor ACR '$VendorAcrName' not found in current subscription ($($account.id))." }
$loginServer = $acr.loginServer
Write-Host "Vendor ACR: $loginServer" -ForegroundColor Green

# ── Check that this tag does not already exist (immutability guard) ──────────
$existing = az acr repository show-tags -n $VendorAcrName --repository $Repository --query "[?@=='$Version']" -o tsv 2>$null
if ($existing) {
    throw "Tag '${Repository}:${Version}' already exists in $VendorAcrName. Bump the version — never overwrite a published weights tag."
}

# ── Confirm the runtime image tag exists (only if attaching) ─────────────────
if ($AttachToImage) {
    $imgTag = az acr repository show-tags -n $VendorAcrName --repository $ImageRepository --query "[?@=='$Version']" -o tsv 2>$null
    if (-not $imgTag) {
        throw "AttachToImage requested but ${ImageRepository}:${Version} does not exist in $VendorAcrName. Publish the runtime image first, then publish weights with -AttachToImage."
    }
}

# ── oras login (uses the same AAD token as az acr) ───────────────────────────
Write-Host "`nLogging oras into $loginServer ..." -ForegroundColor Cyan
$accessToken = az acr login --name $VendorAcrName --expose-token --output tsv --query accessToken 2>$null
if (-not $accessToken) { throw "Failed to acquire an ACR access token for $VendorAcrName." }
# ORAS uses the magic '00000000-0000-0000-0000-000000000000' username for AAD-token auth.
$accessToken | & oras login $loginServer -u '00000000-0000-0000-0000-000000000000' --password-stdin
if ($LASTEXITCODE -ne 0) { throw "oras login failed." }
Write-Host "[OK] oras logged in" -ForegroundColor Green

# ── Push the artifact ────────────────────────────────────────────────────────
# ORAS requires us to be in the directory containing the file so the manifest
# records a clean relative filename (no Windows drive letters in the layer name).
$artifactRef = "$loginServer/${Repository}:${Version}"
$tarDir = $tarItem.DirectoryName
Push-Location $tarDir
try {
    Write-Host "`nPushing $artifactRef ..." -ForegroundColor Cyan
    & oras push $artifactRef `
        --artifact-type $ArtifactType `
        "${tarFileName}:${LayerMediaType}"
    if ($LASTEXITCODE -ne 0) { throw "oras push failed." }
} finally {
    Pop-Location
}
Write-Host "[OK] artifact pushed" -ForegroundColor Green

# ── Optionally attach as a referrer of the runtime image ─────────────────────
if ($AttachToImage) {
    $imageRef = "$loginServer/${ImageRepository}:${Version}"
    Push-Location $tarDir
    try {
        Write-Host "`nAttaching as referrer of $imageRef ..." -ForegroundColor Cyan
        & oras attach $imageRef `
            --artifact-type $ArtifactType `
            "${tarFileName}:${LayerMediaType}"
        if ($LASTEXITCODE -ne 0) { throw "oras attach failed." }
    } finally {
        Pop-Location
    }
    Write-Host "[OK] attached to $imageRef" -ForegroundColor Green
}

# ── Resolve digest of the new manifest ───────────────────────────────────────
$digest = az acr repository show -n $VendorAcrName --image "${Repository}:${Version}" --query digest -o tsv 2>$null
if (-not $digest) { throw "Could not resolve digest for ${Repository}:${Version}." }
Write-Host "Manifest digest: $digest" -ForegroundColor Gray

# ── Lock the tag immutable ──────────────────────────────────────────────────
if ($LockTag) {
    Write-Host "`nLocking tag '${Repository}:${Version}' (write-enabled=false, delete-enabled=false)..." -ForegroundColor Cyan
    az acr repository update `
        --name $VendorAcrName `
        --image "${Repository}:${Version}" `
        --write-enabled false `
        --delete-enabled false `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to lock tag ${Repository}:${Version}." }
    Write-Host "[OK] tag locked" -ForegroundColor Green
}

# ── Summary block — paste into release notes / customer hand-off ────────────
Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Published ${Repository}:${Version}" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Registry:       $loginServer"
Write-Host "  Artifact:       ${Repository}:${Version}"
Write-Host "  Artifact type:  $ArtifactType"
Write-Host "  Layer media:    $LayerMediaType"
Write-Host "  Layer file:     $tarFileName ($tarSizeGiB GiB)"
Write-Host "  Digest:         $digest"
if ($AttachToImage) { Write-Host "  Attached to:    ${ImageRepository}:${Version}" }
if ($LockTag)       { Write-Host "  Tag locked:     yes (immutable)" }
Write-Host ""
Write-Host "  Customer-side pull (server-side blob copy between ACRs):" -ForegroundColor Gray
Write-Host "    oras copy $loginServer/${Repository}:${Version} `\"
Write-Host "              <customerAcr>.azurecr.io/${Repository}:${Version}"
Write-Host ""
