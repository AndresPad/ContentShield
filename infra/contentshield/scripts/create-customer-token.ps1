#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (VENDOR-side) Create a scoped, read-only ACR token a customer can use to
  import ContentShield images into their own ACR.

.DESCRIPTION
  Provisions in YOUR ACR:
    - A scope-map with content/read + metadata/read on the requested repos
    - A token bound to that scope-map with an expiration date
  Prints the credentials the customer needs.

  Re-running with the same -CustomerName rotates the password (new credential).

.PARAMETER AcrName
  Source ACR (yours). Default: contentshieldacr.

.PARAMETER CustomerName
  Short identifier for this customer (becomes part of token name).
  Example: 'acme'  ->  scope-map 'pull-acme', token 'pull-acme'.

.PARAMETER ExpirationDays
  How many days the token stays valid. Default 90.

.PARAMETER Repositories
  Repos the token can pull. Default: contentshield, contentshield-stage2.

.PARAMETER OutFile
  Optional path to a .json file that bundles ACR FQDN + token name + password.
  Send THIS file (or its contents) to the customer through a secure channel.

.EXAMPLE
  .\create-customer-token.ps1 -CustomerName acme -OutFile .\acme-credentials.json
#>
[CmdletBinding()]
param(
    [string]$AcrName = 'contentshieldacr',
    [Parameter(Mandatory)][string]$CustomerName,
    [int]$ExpirationDays = 90,
    [string[]]$Repositories = @('contentshield','contentshield-stage2'),
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$safe = ($CustomerName -replace '[^a-zA-Z0-9-]','').ToLower()
if (-not $safe) { throw "CustomerName produced an empty safe name." }
$scopeMap = "pull-$safe"
$tokenName = "pull-$safe"
$expiry = (Get-Date).AddDays($ExpirationDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$server = (az acr show -n $AcrName --query loginServer -o tsv).Trim()
if (-not $server) { throw "ACR '$AcrName' not found." }

Write-Host "Source ACR : $server" -ForegroundColor Cyan
Write-Host "Customer   : $safe (scope-map=$scopeMap, token=$tokenName)" -ForegroundColor Cyan
Write-Host "Expires    : $expiry" -ForegroundColor Cyan

# Build scope-map repository actions
$repoArgs = @()
foreach ($r in $Repositories) {
    $repoArgs += @('--repository', $r, 'content/read', 'metadata/read')
}

# Idempotent: if the scope-map already exists with wrong actions, recreate it.
$existing = az acr scope-map show -r $AcrName -n $scopeMap --query name -o tsv 2>$null
if ($existing) {
    $existingActions = (az acr scope-map show -r $AcrName -n $scopeMap --query actions -o tsv 2>$null) -split "`n"
    $needed = @()
    foreach ($r in $Repositories) {
        $needed += "repositories/$r/content/read"
        $needed += "repositories/$r/metadata/read"
    }
    $missing = $needed | Where-Object { $_ -notin $existingActions }
    if ($missing.Count -gt 0) {
        Write-Host "Existing scope-map is missing actions ($($missing -join ', ')). Deleting tokens + scope-map to rebuild..." -ForegroundColor Yellow
        # Delete any tokens bound to this scope-map first
        $boundTokens = az acr token list -r $AcrName --query "[?scopeMapId && ends_with(scopeMapId, '/$scopeMap')].name" -o tsv 2>$null
        foreach ($tk in ($boundTokens -split "`n" | Where-Object { $_ })) {
            Write-Host "  removing dependent token $tk" -ForegroundColor DarkYellow
            az acr token delete -r $AcrName -n $tk --yes --only-show-errors | Out-Null
        }
        az acr scope-map delete -r $AcrName -n $scopeMap --yes --only-show-errors | Out-Null
        $existing = $null
    } else {
        Write-Host "Scope-map exists with correct actions." -ForegroundColor Green
    }
}
if (-not $existing) {
    Write-Host "Creating scope-map..." -ForegroundColor Cyan
    az acr scope-map create -r $AcrName -n $scopeMap @repoArgs --only-show-errors | Out-Null
}

# Create or refresh the token (rotates password every run)
$tokenExisted = az acr token show -r $AcrName -n $tokenName --query name -o tsv 2>$null
if (-not $tokenExisted) {
    Write-Host "Creating token..." -ForegroundColor Cyan
    az acr token create -r $AcrName -n $tokenName --scope-map $scopeMap --expiration $expiry --only-show-errors | Out-Null
}

Write-Host "Generating password (1-year max, this is the only time it's shown)..." -ForegroundColor Cyan
$cred = az acr token credential generate -r $AcrName -n $tokenName --expiration $expiry --password1 --only-show-errors -o json | ConvertFrom-Json
$password = $cred.passwords[0].value

$bundle = [pscustomobject]@{
    vendorAcrFqdn      = $server
    vendorAcrTokenName = $tokenName
    vendorAcrTokenPassword = $password
    expiresUtc         = $expiry
    repositories       = $Repositories
}

Write-Host "`n=== CUSTOMER CREDENTIALS (share securely) ===" -ForegroundColor Green
Write-Host "  vendorAcrFqdn         : $($bundle.vendorAcrFqdn)"
Write-Host "  vendorAcrTokenName    : $($bundle.vendorAcrTokenName)"
Write-Host "  vendorAcrTokenPassword: $($bundle.vendorAcrTokenPassword)"
Write-Host "  expiresUtc            : $($bundle.expiresUtc)"
Write-Host "  repositories          : $($bundle.repositories -join ', ')"

if ($OutFile) {
    $bundle | ConvertTo-Json -Depth 5 | Set-Content -Path $OutFile -Encoding utf8
    Write-Host "`nWrote credentials bundle: $OutFile" -ForegroundColor Yellow
    Write-Host "  Encrypt this file before sharing (it contains a secret)." -ForegroundColor Yellow
}

Write-Host "`nCustomer runs:" -ForegroundColor Cyan
Write-Host "  .\deploy.ps1 -ResourceGroup <rg> -ApimPublisherEmail you@co.com ``"
Write-Host "      -VendorAcrFqdn '$($bundle.vendorAcrFqdn)' ``"
Write-Host "      -VendorAcrTokenName '$($bundle.vendorAcrTokenName)' ``"
Write-Host "      -VendorAcrTokenPassword '<password>'"
