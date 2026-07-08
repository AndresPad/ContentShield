#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (CUSTOMER-side, called from deploy.ps1) Server-side import of ContentShield
  images from the vendor's ACR into the customer's new ACR using a scoped token.

.DESCRIPTION
  Uses `az acr import --username/--password` to copy each repo:tag from
  <vendorAcrFqdn> into <targetAcrName>. The transfer is blob-to-blob inside
  Azure — no local docker/disk needed, takes seconds. -a

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

.PARAMETER EnableArtifactStreaming
  After import, enable ACR Artifact Streaming on each target repo (auto-on)
  AND force-create a streaming manifest for each freshly imported tag.
  Drops stage-2 cold-start from minutes to seconds. Requires Premium ACR.
  On by default; pass -EnableArtifactStreaming:$false to skip.

.PARAMETER UseAad
  Use AAD/MI auth for the vendor ACR pull (no token name/password needed).
  Requires the *current* az login identity to have AcrPull on the vendor ACR.
  Intended for internal-Microsoft customers where vendor + customer are in
  the same tenant. When -UseAad is set, -VendorAcrTokenName/-VendorAcrTokenPassword
  may be omitted; if supplied they are ignored.

.PARAMETER DigestMap
  Hashtable of @{ friendlyTag = 'sha256:<hex>' } pairs. When supplied, the
  script ignores -Tag / -AllTags and imports the listed digests, retagging
  each as ':<friendlyTag>' in the target ACR. Use this for variant-matrix
  testing where you want to pin specific image digests under human-readable
  names. Requires exactly one entry in -Repositories.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetAcrName,
    [Parameter(Mandatory)][string]$VendorAcrFqdn,
    [string]$VendorAcrTokenName,
    [string]$VendorAcrTokenPassword,
    [string[]]$Repositories = @('contentshield','contentshield-stage2'),
    [string]$Tag = 'latest',
    [switch]$AllTags,
    [switch]$Force,
    [bool]$EnableArtifactStreaming = $true,
    [switch]$UseAad,
    [hashtable]$DigestMap
)

$ErrorActionPreference = 'Stop'

if (-not $UseAad) {
    if (-not $VendorAcrTokenName -or -not $VendorAcrTokenPassword) {
        throw "Either pass -UseAad (AAD auth) OR both -VendorAcrTokenName and -VendorAcrTokenPassword (scoped-token auth)."
    }
}

if ($DigestMap -and $Repositories.Count -ne 1) {
    throw "-DigestMap requires exactly one repository in -Repositories (got $($Repositories.Count): $($Repositories -join ', '))."
}

# Helper: list tags in a remote ACR repo via the Docker Registry v2 API using
# the scoped token. ACR's data-plane requires a two-step Basic -> Bearer token
# exchange before /v2/<repo>/tags/list works.
function Get-RemoteTags {
    param([string]$Fqdn, [string]$Repo, [string]$Username, [string]$Password, [switch]$UseAad)
    try {
        if ($UseAad) {
            # AAD path: exchange an AAD access token for an ACR refresh+access token.
            $aadToken = az account get-access-token --resource "https://$Fqdn" --query accessToken -o tsv 2>$null
            if (-not $aadToken) {
                # Fallback to ARM resource if data-plane resource isn't accepted in the cloud.
                $aadToken = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv
            }
            $refresh = Invoke-RestMethod -Method POST -Uri "https://$Fqdn/oauth2/exchange" `
                -Body @{ grant_type='access_token'; service=$Fqdn; access_token=$aadToken } -ErrorAction Stop
            $accessResp = Invoke-RestMethod -Method POST -Uri "https://$Fqdn/oauth2/token" `
                -Body @{ grant_type='refresh_token'; service=$Fqdn; scope="repository:${Repo}:metadata_read"; refresh_token=$refresh.refresh_token } -ErrorAction Stop
            $bearer = $accessResp.access_token
        } else {
            $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
            $tokenResp = Invoke-RestMethod -Method GET `
                -Uri "https://$Fqdn/oauth2/token?service=$Fqdn&scope=repository:${Repo}:metadata_read" `
                -Headers @{ Authorization = "Basic $basic" } -ErrorAction Stop
            if (-not $tokenResp.access_token) { throw "Token exchange returned no access_token." }
            $bearer = $tokenResp.access_token
        }
        $resp = Invoke-RestMethod -Method GET `
            -Uri "https://$Fqdn/v2/$Repo/tags/list" `
            -Headers @{ Authorization = "Bearer $bearer" } -ErrorAction Stop
    } catch {
        throw "Could not list tags for $Fqdn/$Repo. ($_)"
    }
    if (-not $resp.tags) { return @() }
    return @($resp.tags)
}

Write-Host "`nImporting images from $VendorAcrFqdn -> $TargetAcrName.azurecr.io" -ForegroundColor Cyan

# Helper: get the newest tag in a remote ACR repo (by lastUpdateTime) using the
# ACR-specific /acr/v1 catalog endpoint.
function Get-NewestTag {
    param([string]$Fqdn, [string]$Repo, [string]$Username, [string]$Password, [switch]$UseAad)
    try {
        if ($UseAad) {
            $aadToken = az account get-access-token --resource "https://$Fqdn" --query accessToken -o tsv 2>$null
            if (-not $aadToken) {
                $aadToken = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv
            }
            $refresh = Invoke-RestMethod -Method POST -Uri "https://$Fqdn/oauth2/exchange" `
                -Body @{ grant_type='access_token'; service=$Fqdn; access_token=$aadToken } -ErrorAction Stop
            $accessResp = Invoke-RestMethod -Method POST -Uri "https://$Fqdn/oauth2/token" `
                -Body @{ grant_type='refresh_token'; service=$Fqdn; scope="repository:${Repo}:metadata_read"; refresh_token=$refresh.refresh_token } -ErrorAction Stop
            $bearer = $accessResp.access_token
        } else {
            $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
            $tokenResp = Invoke-RestMethod -Method GET `
                -Uri "https://$Fqdn/oauth2/token?service=$Fqdn&scope=repository:${Repo}:metadata_read" `
                -Headers @{ Authorization = "Basic $basic" } -ErrorAction Stop
            $bearer = $tokenResp.access_token
        }
        $resp = Invoke-RestMethod -Method GET `
            -Uri "https://$Fqdn/acr/v1/$Repo/_tags?orderby=timedesc&n=1" `
            -Headers @{ Authorization = "Bearer $bearer" } -ErrorAction Stop
        if ($resp.tags -and $resp.tags.Count -gt 0) { return $resp.tags[0].name }
    } catch {
        Write-Host "  (Could not fetch newest tag for $Repo : $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
    return $null
}

foreach ($repo in $Repositories) {

    if ($DigestMap) {
        # Digest-pinned import mode. Each entry imports a specific sha256 manifest
        # and retags it under the human-readable friendlyTag in the target ACR.
        # No ':latest' alias here — variant testing wants explicit, traceable tags.
        Write-Host "  DigestMap mode: importing $($DigestMap.Count) digest(s) for $repo" -ForegroundColor Gray
        foreach ($entry in $DigestMap.GetEnumerator()) {
            $friendlyTag = $entry.Key
            $digest = $entry.Value
            if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
                throw "DigestMap['$friendlyTag'] = '$digest' is not a valid sha256:<hex> reference."
            }
            $source = "${VendorAcrFqdn}/${repo}@${digest}"
            Write-Host "  $source -> ${repo}:${friendlyTag}" -ForegroundColor Gray

            $argsList = @(
                'acr','import',
                '-n', $TargetAcrName,
                '--source', $source,
                '--image', "${repo}:${friendlyTag}",
                '--only-show-errors'
            )
            if (-not $UseAad) {
                $argsList += @('--username', $VendorAcrTokenName, '--password', $VendorAcrTokenPassword)
            }
            if ($Force) { $argsList += '--force' }

            az @argsList 2>&1 | Tee-Object -Variable importOutput | Out-Host
            if ($LASTEXITCODE -ne 0) {
                $msg = ($importOutput | Out-String)
                if ($msg -match 'MANIFEST_UNKNOWN') {
                    Write-Host "`n  >> Digest '$digest' does not exist in '$repo' on $VendorAcrFqdn." -ForegroundColor Red
                }
                throw "Digest import failed for $source."
            }
            Write-Host "  [OK] imported ${repo}@${digest} as ${repo}:${friendlyTag}" -ForegroundColor Green

            if ($EnableArtifactStreaming) {
                Write-Host "  Creating artifact-streaming manifest for ${repo}:${friendlyTag} ..." -ForegroundColor DarkGray
                az acr artifact-streaming create `
                    --name $TargetAcrName `
                    --image "${repo}:${friendlyTag}" `
                    --only-show-errors 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    [warn] artifact-streaming create failed for ${repo}:${friendlyTag}. Continuing (ACR Premium required; preview feature in some regions)." -ForegroundColor Yellow
                    $LASTEXITCODE = 0
                }
            }
        }

        # Repo-level auto-streaming flag (same as the tag-mode path).
        if ($EnableArtifactStreaming) {
            Write-Host "  Enabling auto artifact-streaming on repo '$repo' ..." -ForegroundColor DarkGray
            az acr artifact-streaming update `
                --name $TargetAcrName `
                --repository $repo `
                --enable-streaming True `
                --only-show-errors 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [warn] artifact-streaming update failed for repo '$repo'. Continuing." -ForegroundColor Yellow
                $LASTEXITCODE = 0
            }
        }
        continue  # skip the tag-based block below for this repo
    }

    # Determine which tags to import
    if ($AllTags) {
        Write-Host "  Listing tags for $repo via Registry v2 API..." -ForegroundColor Gray
        $tagsToImport = Get-RemoteTags -Fqdn $VendorAcrFqdn -Repo $repo `
            -Username $VendorAcrTokenName -Password $VendorAcrTokenPassword -UseAad:$UseAad
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
            -Username $VendorAcrTokenName -Password $VendorAcrTokenPassword -UseAad:$UseAad
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
            '--image', "${repo}:${t}",
            '--only-show-errors'
        )
        if (-not $UseAad) {
            $argsList += @('--username', $VendorAcrTokenName, '--password', $VendorAcrTokenPassword)
        }
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

        # ── Artifact Streaming: force-create a streaming manifest for this
        #    just-imported tag so the first pull on a fresh node is streamed.
        if ($EnableArtifactStreaming) {
            $tagsToStream = @($t)
            if ($t -eq $aliasLatestFromTag -and $t -ne 'latest') { $tagsToStream += 'latest' }
            foreach ($st in $tagsToStream) {
                Write-Host "  Creating artifact-streaming manifest for ${repo}:${st} ..." -ForegroundColor DarkGray
                az acr artifact-streaming create `
                    --name $TargetAcrName `
                    --image "${repo}:${st}" `
                    --only-show-errors 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    [warn] artifact-streaming create failed for ${repo}:${st}. Continuing (ACR Premium required; preview feature in some regions)." -ForegroundColor Yellow
                    $LASTEXITCODE = 0
                }
            }
        }
    }

    # ── Artifact Streaming: turn ON auto-conversion for the whole repo, so
    #    every future push/import is converted without any extra step.
    if ($EnableArtifactStreaming) {
        Write-Host "  Enabling auto artifact-streaming on repo '$repo' ..." -ForegroundColor DarkGray
        # Newer az acr CLI renamed --enable-auto-streaming -> --enable-streaming.
        az acr artifact-streaming update `
            --name $TargetAcrName `
            --repository $repo `
            --enable-streaming True `
            --only-show-errors 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [warn] artifact-streaming update failed for repo '$repo'. Continuing." -ForegroundColor Yellow
            $LASTEXITCODE = 0
        }
    }
}
Write-Host "Image sync complete." -ForegroundColor Green
