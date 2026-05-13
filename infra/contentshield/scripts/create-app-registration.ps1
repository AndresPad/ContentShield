#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Create a replica of the RatioAIDev Entra ID app registration in the current tenant.

.DESCRIPTION
  Provisions a new multi-tenant app registration mirroring the shape of the source
  app (RatioAIDev, AppId aceb273b-5301-46a4-91c9-c17ef0ff92e9), then creates the
  corresponding enterprise application (service principal) and a client secret.

  Output is printed to the console AND optionally written to a .env file.

.PARAMETER DisplayName
  Display name for the new app registration. Default: 'RatioAIDev-<tenant-short>'.

.PARAMETER SignInAudience
  Sign-in audience. Default: 'AzureADMyOrg'.

.PARAMETER OutEnvFile
  Optional path to write the resulting client id / tenant id / secret as KEY=VALUE.

.EXAMPLE
  .\create-app-registration.ps1
  .\create-app-registration.ps1 -DisplayName "ContentShield-Dev" -OutEnvFile .\.env.app
#>
[CmdletBinding()]
param(
    [string]$DisplayName,
    [ValidateSet('AzureADMyOrg','AzureADMultipleOrgs','AzureADandPersonalMicrosoftAccount')]
    [string]$SignInAudience = 'AzureADMyOrg',
    [string]$OutEnvFile
)

$ErrorActionPreference = 'Stop'

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "Not logged into Azure CLI. Run 'az login --allow-no-subscriptions' first." }

if (-not $DisplayName) {
    $tenantShort = $acct.tenantId.Substring(0,8)
    $DisplayName = "RatioAIDev-$tenantShort"
}

Write-Host "Creating app registration '$DisplayName' (audience=$SignInAudience)..." -ForegroundColor Cyan
$createJson = az ad app create `
    --display-name $DisplayName `
    --sign-in-audience $SignInAudience `
    -o json
if ($LASTEXITCODE -ne 0) { throw "az ad app create failed." }
$app = $createJson | ConvertFrom-Json

Write-Host "  App (Client) ID : $($app.appId)" -ForegroundColor Green
Write-Host "  Object ID       : $($app.id)" -ForegroundColor Green

# Service principal (enterprise app)
Write-Host "Creating service principal..." -ForegroundColor Cyan
$spJson = az ad sp create --id $app.appId -o json 2>$null
if ($LASTEXITCODE -ne 0) {
    # Possibly already exists, fetch it
    $spJson = az ad sp show --id $app.appId -o json
}
$sp = $spJson | ConvertFrom-Json
Write-Host "  SP Object ID    : $($sp.id)" -ForegroundColor Green

# Client secret (24 months)
Write-Host "Creating client secret (24 months)..." -ForegroundColor Cyan
$secretJson = az ad app credential reset `
    --id $app.appId `
    --display-name "deploy-secret" `
    --years 2 `
    -o json
$secret = $secretJson | ConvertFrom-Json

Write-Host "`n=== App registration created ===" -ForegroundColor Cyan
Write-Host "Display Name : $DisplayName"
Write-Host "Tenant Id    : $($acct.tenantId)"
Write-Host "Client Id    : $($app.appId)"
Write-Host "Client Secret: $($secret.password)"
Write-Host ""
Write-Host "Use this Client Id with the bicep parameter 'ratioAiDevClientId'." -ForegroundColor Yellow

if ($OutEnvFile) {
    @(
        "AZURE_TENANT_ID=$($acct.tenantId)",
        "AZURE_CLIENT_ID=$($app.appId)",
        "AZURE_CLIENT_SECRET=$($secret.password)",
        "RATIO_AI_DEV_CLIENT_ID=$($app.appId)"
    ) | Set-Content -Path $OutEnvFile -Encoding utf8
    Write-Host "Wrote $OutEnvFile" -ForegroundColor Green
}
