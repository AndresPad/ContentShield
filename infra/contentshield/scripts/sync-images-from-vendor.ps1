#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (CUSTOMER-side, called from deploy.ps1) Server-side import of ContentShield
  images from the vendor's ACR into the customer's new ACR using a scoped token.

.DESCRIPTION
  Uses `az acr import --username/--password` to copy each repo:tag from
  <vendorAcrFqdn> into <targetAcrName>. The transfer is blob-to-blob inside
  Azure — no local docker/disk needed, takes seconds.

  Each image is imported with the requested tag AND tagged as ':latest'.

.PARAMETER TargetAcrName
  Customer's ACR name (not FQDN).

.PARAMETER VendorAcrFqdn
  Source ACR FQDN, e.g. 'contentshieldacr.azurecr.io'.

.PARAMETER VendorAcrTokenName
  Username for the scoped token (e.g. 'pull-acme').

.PARAMETER VendorAcrTokenPassword
  Password for the scoped token.

.PARAMETER Repositories
  Default: contentshield, contentshield-stage2.

.PARAMETER Tag
  Default: latest.

.PARAMETER Force
  Pass --force to overwrite existing target tags.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetAcrName,
    [Parameter(Mandatory)][string]$VendorAcrFqdn,
    [Parameter(Mandatory)][string]$VendorAcrTokenName,
    [Parameter(Mandatory)][string]$VendorAcrTokenPassword,
    [string[]]$Repositories = @('contentshield','contentshield-stage2'),
    [string]$Tag = 'latest',
    [switch]$AllTags,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Helper: list tags in a remote ACR repo via the Docker Registry v2 API using the scoped token.
function Get-RemoteTags {
    param([string]$Fqdn, [string]$Repo, [string]$Username, [string]$Password)
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
    $headers = @{ Authorization = "Basic $basic" }
    try {
        $resp = Invoke-RestMethod -Uri "https://$Fqdn/v2/$Repo/tags/list" -Headers $headers -Method GET -ErrorAction Stop
    } catch {
        throw "Could not list tags for $Fqdn/$Repo. The scoped token must have 'metadata/read' on the repo. ($_)"
    }
    if (-not $resp.tags) { return @() }
    return @($resp.tags)
}

Write-Host "`nImporting images from $VendorAcrFqdn -> $TargetAcrName.azurecr.io" -ForegroundColor Cyan

# Helper: get the newest tag in a remote ACR repo (by lastUpdateTime) using the
# ACR-specific /acr/v1 catalog endpoint.
function Get-NewestTag {
    param([string]$Fqdn, [string]$Repo, [string]$Username, [string]$Password)
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
    $headers = @{ Authorization = "Basic $basic" }
    try {
        $resp = Invoke-RestMethod -Method GET `
            -Uri "https://$Fqdn/acr/v1/$Repo/_tags?orderby=timedesc&n=1" `
            -Headers $headers -ErrorAction Stop
        if ($resp.tags -and $resp.tags.Count -gt 0) { return $resp.tags[0].name }
    } catch {
        Write-Host "  (Could not fetch newest tag for $Repo : $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
    return $null
}

foreach ($repo in $Repositories) {

    # Determine which tags to import
    if ($AllTags) {
        Write-Host "  Listing tags for $repo via Registry v2 API..." -ForegroundColor Gray
        $tagsToImport = Get-RemoteTags -Fqdn $VendorAcrFqdn -Repo $repo `
            -Username $VendorAcrTokenName -Password $VendorAcrTokenPassword
        if (-not $tagsToImport) {
            Write-Host "  [skip] No tags found in $repo on source." -ForegroundColor Yellow
            continue
        }
        Write-Host ("  Found {0} tag(s): {1}" -f $tagsToImport.Count, ($tagsToImport -join ', ')) -ForegroundColor Gray
    } else {
        $tagsToImport = @($Tag)
    }

    # Decide which tag to ALSO alias as ':latest' in the target.
    # Priority: explicit -Tag if it's in the import set; otherwise the newest tag on the source.
    $aliasLatestFromTag = $null
    if ($Tag -and $tagsToImport -contains $Tag) {
        $aliasLatestFromTag = $Tag
    } elseif ($AllTags) {
        $aliasLatestFromTag = Get-NewestTag -Fqdn $VendorAcrFqdn -Repo $repo `
            -Username $VendorAcrTokenName -Password $VendorAcrTokenPassword
        if (-not $aliasLatestFromTag) { $aliasLatestFromTag = $tagsToImport[0] }  # fallback
    } else {
        $aliasLatestFromTag = $Tag
    }
    if ($aliasLatestFromTag) {
        Write-Host "  '${repo}:$aliasLatestFromTag' will also be tagged as ':latest' in the target." -ForegroundColor DarkGray
    }

    foreach ($t in $tagsToImport) {
        $source = "$VendorAcrFqdn/${repo}:${t}"
        Write-Host "  $source ..." -ForegroundColor Gray

        $argsList = @(
            'acr','import',
            '-n', $TargetAcrName,
            '--source', $source,
            '--username', $VendorAcrTokenName,
            '--password', $VendorAcrTokenPassword,
            '--image', "${repo}:${t}",
            '--only-show-errors'
        )
        if ($t -eq $aliasLatestFromTag) {
            $argsList += @('--image', "${repo}:latest")
        }
        if ($Force) { $argsList += '--force' }

        az @argsList 2>&1 | Tee-Object -Variable importOutput | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $msg = ($importOutput | Out-String)
            if ($msg -match 'MANIFEST_UNKNOWN' -or $msg -match 'manifest tagged by') {
                Write-Host "`n  >> The tag '$t' does not exist in the source repo '$repo' on $VendorAcrFqdn." -ForegroundColor Red
                Write-Host "  >> Ask the vendor to either re-tag a build as ':$t' in their ACR, or" -ForegroundColor Yellow
                Write-Host "  >> tell you which tag to use, then re-run with -ImageTag '<thatTag>' (or -AllTags)." -ForegroundColor Yellow
            }
            throw "Import failed for $source."
        }
        $extra = if ($t -eq $aliasLatestFromTag) { ' and :latest' } else { '' }
        Write-Host "  [OK] imported ${repo}:${t}$extra" -ForegroundColor Green
    }
}
Write-Host "Image sync complete." -ForegroundColor Green
