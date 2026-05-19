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

.PARAMETER WithWeights
  After publishing the regular image, also build & publish the weights-baked
  variant (services/stage2/Dockerfile.baked) into <BakedRepository>:<Version>.
  Only valid when -Repository = 'contentshield-stage2'. Requires:
    * the 'oras' CLI on PATH
    * an already-published weights artifact at
        <VendorAcrName>.azurecr.io/<WeightsRepository>:<Version>
      (publish via scripts/publish-weights.ps1 BEFORE running with -WithWeights)
    * disk + bandwidth for one pull/upload of the weights tarball
  The weights tarball is pulled locally, extracted into <ContextPath>/_weights/,
  built via 'az acr build', then deleted.

.PARAMETER BakedRepository
  Repository name for the weights-baked variant. Default 'contentshield-stage2-baked'.
  Only used when -WithWeights is set.

.PARAMETER WeightsRepository
  Source repository for the weights OCI artifact in the same vendor ACR.
  Default 'contentshield-stage2-weights'. Only used when -WithWeights is set.

.PARAMETER BakedDockerfile
  Dockerfile used to build the baked variant. Default 'Dockerfile.baked'
  (relative to -ContextPath). Only used when -WithWeights is set.

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
    [switch]$Sign,
    [switch]$WithWeights,
    [string]$BakedRepository = 'contentshield-stage2-baked',
    [string]$WeightsRepository = 'contentshield-stage2-weights',
    [string]$BakedDockerfile = 'Dockerfile.baked'
)

$ErrorActionPreference = 'Stop'

# ── Validate -WithWeights option combinations ────────────────────────────────
if ($WithWeights -and $Repository -ne 'contentshield-stage2') {
    throw "-WithWeights is only valid for the 'contentshield-stage2' repository (got '$Repository')."
}

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

# ============================================================================
# Optional: build & publish the weights-baked variant
# ============================================================================
if (-not $WithWeights) { return }

Write-Host "`n--- Building weights-baked variant ---" -ForegroundColor Cyan

# ── Validate oras ────────────────────────────────────────────────────────────
$orasCmd = Get-Command oras -ErrorAction SilentlyContinue
if (-not $orasCmd) {
    throw @"
-WithWeights requested but 'oras' CLI is not on PATH.
Install from https://oras.land/docs/installation, e.g.:
  winget install ORAS.ORAS
"@
}
$orasBin = $orasCmd.Source

# ── Validate Dockerfile.baked exists ─────────────────────────────────────────
$bakedDfPath = Join-Path $ContextPath $BakedDockerfile
if (-not (Test-Path -LiteralPath $bakedDfPath -PathType Leaf)) {
    throw "Baked Dockerfile not found at '$bakedDfPath'. Pass -BakedDockerfile or -ContextPath."
}

# ── Verify weights artifact exists in vendor ACR ─────────────────────────────
$weightsTag = az acr repository show-tags -n $VendorAcrName --repository $WeightsRepository --query "[?@=='$Version']" -o tsv 2>$null
if (-not $weightsTag) {
    throw "-WithWeights requires ${WeightsRepository}:${Version} to exist in $VendorAcrName. Publish via scripts/publish-weights.ps1 first."
}

# ── Refuse to overwrite an existing baked tag ───────────────────────────────
$existingBaked = az acr repository show-tags -n $VendorAcrName --repository $BakedRepository --query "[?@=='$Version']" -o tsv 2>$null
if ($existingBaked) {
    throw "Tag '${BakedRepository}:${Version}' already exists in $VendorAcrName. Bump the version — never overwrite a published tag."
}

# ── oras login (AAD token via az acr login --expose-token) ───────────────────
Write-Host "`nLogging oras into $($acr.loginServer) ..." -ForegroundColor Cyan
$accessToken = az acr login --name $VendorAcrName --expose-token --output tsv --query accessToken 2>$null
if (-not $accessToken) { throw "Failed to acquire an ACR access token for $VendorAcrName." }
$accessToken | & $orasBin login $acr.loginServer -u '00000000-0000-0000-0000-000000000000' --password-stdin
if ($LASTEXITCODE -ne 0) { throw "oras login failed." }

# ── Stage weights into the build context (./_weights) ───────────────────────
$weightsStaging = Join-Path $ContextPath '_weights'
if (Test-Path $weightsStaging) { Remove-Item -Recurse -Force $weightsStaging }
New-Item -ItemType Directory -Path $weightsStaging | Out-Null

try {
    Write-Host "`nPulling ${WeightsRepository}:${Version} into $weightsStaging ..." -ForegroundColor Cyan
    & $orasBin pull "$($acr.loginServer)/${WeightsRepository}:${Version}" -o $weightsStaging
    if ($LASTEXITCODE -ne 0) { throw "oras pull failed." }

    # Extract every tarball into the staging dir so the COPY layout works.
    $tars = Get-ChildItem -Path $weightsStaging -File | Where-Object {
        $_.Name -match '\.(tar\.gz|tgz|tar\.zst|tar)$'
    }
    if (-not $tars) {
        throw "No .tar/.tar.gz/.tar.zst files in pulled artifact at $weightsStaging."
    }
    foreach ($t in $tars) {
        Write-Host "Extracting $($t.Name) ..." -ForegroundColor Gray
        if ($t.Name -match '\.tar\.zst$') {
            $zstd = Get-Command zstd -ErrorAction SilentlyContinue
            if (-not $zstd) { throw "$($t.Name) is zstd-compressed but 'zstd' is not on PATH." }
            & tar --use-compress-program=unzstd -xf $t.FullName -C $weightsStaging
        } else {
            & tar -xzf $t.FullName -C $weightsStaging
        }
        if ($LASTEXITCODE -ne 0) { throw "tar extraction of $($t.Name) failed." }
        Remove-Item -Force $t.FullName
    }

    $bakedImageRef = "${BakedRepository}:${Version}"
    $appImageFullRef = "$($acr.loginServer)/${imageRef}"

    Write-Host "`nBuilding $($acr.loginServer)/$bakedImageRef on $appImageFullRef ..." -ForegroundColor Cyan
    Write-Host "  (uploading $weightsStaging to ACR Tasks — this can take a while for multi-GB weights)" -ForegroundColor Gray
    $bakedExtraTags = @()
    if ($MoveLatest) { $bakedExtraTags += "${BakedRepository}:latest" }

    $bakedBuildArgs = @(
        'acr','build',
        '-r', $VendorAcrName,
        '-t', $bakedImageRef,
        '-f', $BakedDockerfile,
        '--platform', $Platform,
        '--build-arg', "APP_IMAGE=$appImageFullRef"
    )
    foreach ($t in $bakedExtraTags) { $bakedBuildArgs += @('-t', $t) }
    $bakedBuildArgs += @('--only-show-errors', $ContextPath)

    az @bakedBuildArgs
    if ($LASTEXITCODE -ne 0) { throw "az acr build (baked) failed." }
    Write-Host "[OK] baked build complete" -ForegroundColor Green

    $bakedDigest = az acr repository show -n $VendorAcrName --image $bakedImageRef --query digest -o tsv
    if (-not $bakedDigest) { throw "Could not resolve digest for $bakedImageRef." }

    if ($LockTag) {
        Write-Host "`nLocking tag '$bakedImageRef' ..." -ForegroundColor Cyan
        az acr repository update `
            --name $VendorAcrName `
            --image $bakedImageRef `
            --write-enabled false `
            --delete-enabled false `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to lock tag $bakedImageRef." }
        Write-Host "[OK] baked tag locked" -ForegroundColor Green
    }

    Write-Host "`n======================================" -ForegroundColor Green
    Write-Host "  Published $bakedImageRef" -ForegroundColor Green
    Write-Host "======================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Registry:   $($acr.loginServer)"
    Write-Host "  Image:      $bakedImageRef"
    Write-Host "  Based on:   $appImageFullRef"
    Write-Host "  Weights:    ${WeightsRepository}:${Version}"
    Write-Host "  Digest:     $bakedDigest"
    if ($MoveLatest) { Write-Host "  Also tagged: :latest" -ForegroundColor Yellow }
    if ($LockTag)    { Write-Host "  Tag locked: yes (immutable)" }
    Write-Host ""
    Write-Host "  Customer-side: deploy with -WeightsInImage \$true (Bicep param)." -ForegroundColor Gray
    Write-Host ""
} finally {
    if (Test-Path $weightsStaging) {
        Write-Host "Cleaning up $weightsStaging ..." -ForegroundColor Gray
        Remove-Item -Recurse -Force $weightsStaging
    }
}
