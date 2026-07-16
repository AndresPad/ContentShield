#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Delete ALL resources in a resource group without deleting the resource group itself.

.DESCRIPTION
  Preserves the resource group (and all role assignments on it).
  Deletes resources in dependency-safe order:
    1. Container Apps        (release env dependency)
    2. APIM                  (release subnet)
    3. Container Apps Env    (release subnet)
    4. ACR
    5. Content Safety        (with --no-wait then purge if soft-delete enabled)
    6. App Insights, Log Analytics, smart alert rules
    7. VNet                  (release NSG/NAT GW associations)
    8. NSGs
    9. NAT Gateway
   10. Public IP
   11. Anything else left over (best-effort sweep)

.PARAMETER ResourceGroup
  Target resource group. MUST exist.

.PARAMETER Force
  Skip confirmation prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

Write-Host "`n!!! DELETE ALL RESOURCES in '$ResourceGroup' !!!" -ForegroundColor Red
Write-Host "    The resource group itself will be PRESERVED." -ForegroundColor Yellow

if (-not $Force) {
    $confirm = Read-Host "Type the resource group name to confirm"
    if ($confirm -ne $ResourceGroup) { Write-Host "Aborted." -ForegroundColor Yellow; exit 1 }
}

$rgExists = az group exists --name $ResourceGroup
if ($rgExists -ne 'true') { throw "Resource group '$ResourceGroup' does not exist." }

$location = az group show -n $ResourceGroup --query location -o tsv

function Remove-ByType {
    param([string]$Type, [string]$Label, [switch]$NoWait)
    $items = az resource list -g $ResourceGroup --resource-type $Type --query "[].id" -o tsv 2>$null
    if (-not $items) { return }
    foreach ($id in $items -split "`n" | Where-Object { $_ }) {
        Write-Host "  Deleting $Label : $id" -ForegroundColor Gray
        if ($NoWait) {
            az resource delete --ids $id --verbose --no-wait 2>$null | Out-Null
        } else {
            az resource delete --ids $id --verbose 2>$null | Out-Null
        }
    }
}

Write-Host "`n[1/11] Container Apps..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.App/containerApps' -Label 'ContainerApp'

Write-Host "[2/11] API Management..." -ForegroundColor Cyan
$apims = az resource list -g $ResourceGroup --resource-type 'Microsoft.ApiManagement/service' --query "[].name" -o tsv 2>$null
foreach ($apim in $apims -split "`n" | Where-Object { $_ }) {
    Write-Host "  Deleting APIM $apim (this can take several minutes)..." -ForegroundColor Gray
    az apim delete -g $ResourceGroup -n $apim --yes --no-wait 2>$null | Out-Null
}
# Wait for APIM deletions to release the subnet before deleting VNet later.
if ($apims) {
    Write-Host "  Waiting up to 25 min for APIM deletion to release subnet..." -ForegroundColor Gray
    $deadline = (Get-Date).AddMinutes(25)
    while ((Get-Date) -lt $deadline) {
        $remaining = @(az resource list -g $ResourceGroup --resource-type 'Microsoft.ApiManagement/service' --query "[].id" -o tsv 2>$null | Where-Object { $_ }).Count
        if ($remaining -eq 0) { break }
        Start-Sleep -Seconds 30
        Write-Host "    ...still waiting ($remaining APIM left)" -ForegroundColor DarkGray
    }

    # APIM soft-deletes on delete. Purge each soft-deleted service so a redeploy
    # with the same name is not blocked by ServiceAlreadyExistsInSoftDeletedState.
    foreach ($apim in $apims -split "`n" | Where-Object { $_ }) {
        Write-Host "  Purging soft-deleted APIM $apim (can take several minutes)..." -ForegroundColor Gray
        az apim deletedservice purge --service-name $apim --location $location 2>$null | Out-Null
    }
}

Write-Host "[3/11] Container Apps Environments..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.App/managedEnvironments' -Label 'ManagedEnvironment'

Write-Host "[4/11] Container Registries..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.ContainerRegistry/registries' -Label 'ACR'

Write-Host "[5/11] Cognitive Services (Content Safety)..." -ForegroundColor Cyan
$css = az resource list -g $ResourceGroup --resource-type 'Microsoft.CognitiveServices/accounts' --query "[].{n:name}" -o json | ConvertFrom-Json
foreach ($cs in $css) {
    Write-Host "  Deleting CS $($cs.n)" -ForegroundColor Gray
    az cognitiveservices account delete -g $ResourceGroup -n $cs.n 2>$null | Out-Null
    Write-Host "  Purging CS $($cs.n) (soft-delete)" -ForegroundColor Gray
    az cognitiveservices account purge -g $ResourceGroup -n $cs.n -l $location 2>$null | Out-Null
}

Write-Host "[6/11] App Insights / smart alerts / Log Analytics..." -ForegroundColor Cyan
Remove-ByType -Type 'microsoft.alertsmanagement/smartDetectorAlertRules' -Label 'SmartAlert'
Remove-ByType -Type 'microsoft.insights/components' -Label 'AppInsights'
Remove-ByType -Type 'Microsoft.OperationalInsights/workspaces' -Label 'LogAnalytics'

Write-Host "[6b] Storage Accounts..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.Storage/storageAccounts' -Label 'StorageAccount'

Write-Host "[7/11] Virtual Networks..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.Network/virtualNetworks' -Label 'VNet'

Write-Host "[8/11] Network Security Groups..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.Network/networkSecurityGroups' -Label 'NSG'

Write-Host "[9/11] NAT Gateways..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.Network/natGateways' -Label 'NATGateway'

Write-Host "[10/11] Public IPs..." -ForegroundColor Cyan
Remove-ByType -Type 'Microsoft.Network/publicIPAddresses' -Label 'PublicIP'

Write-Host "[11/11] Sweeping anything left over..." -ForegroundColor Cyan
$leftover = az resource list -g $ResourceGroup --query "[].id" -o tsv 2>$null
if ($leftover) {
    foreach ($id in $leftover -split "`n" | Where-Object { $_ }) {
        Write-Host "  Sweeping: $id" -ForegroundColor Gray
        az resource delete --ids $id --verbose 2>$null | Out-Null
    }
}

$final = @(az resource list -g $ResourceGroup --query "[].id" -o tsv 2>$null | Where-Object { $_ }).Count
Write-Host "`nReset complete. Resources remaining in '$ResourceGroup': $final" -ForegroundColor Green
if ($final -ne 0) {
    Write-Host "  (Re-run -Reset if anything stubborn remains — some deletions are async.)" -ForegroundColor Yellow
}

# Ensure a clean, deterministic exit code so callers (deploy.ps1 -Reset) do not
# mistake a non-zero code from the last az call for a reset failure.
$global:LASTEXITCODE = 0
exit 0
