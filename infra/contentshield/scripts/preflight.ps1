#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Validate that the current subscription is ready to deploy ContentShield.

.DESCRIPTION
  Checks (in order):
    1. Azure CLI login + active subscription
    2. Resource group exists (NEVER creates it — role assignments preserved)
    3. Caller has Contributor + Role Based Access Control Administrator (or Owner)
       on the RG (RBAC role is needed for the AcrPull role assignment).
    4. Required resource providers are Registered. Auto-registers any that are not.
    5. Region availability for each resource type.
    6. Sufficient `Consumption-GPU-NC24-A100` quota in the target region (when not skipping stage-2).
    7. Container Apps + Container Registry name collision globally (best-effort DNS check).

.PARAMETER ResourceGroup
  Target resource group. Must exist.

.PARAMETER Location
  Azure region. Default westus3.

.PARAMETER CheckGpuQuota
  Verify GPU quota exists. Pass $false when stage-2 deployment is skipped.

.PARAMETER AutoRegister
  Auto-register missing resource providers (default: $true).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'westus3',
    [bool]$CheckGpuQuota = $true,
    [bool]$AutoRegister = $true
)

$ErrorActionPreference = 'Continue'
$failed = $false

function Write-Result {
    param([string]$Title, [string]$Status, [string]$Detail = '')
    $color = switch ($Status) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}{2}" -f $Status, $Title, $(if ($Detail) { " — $Detail" } else { '' })) -ForegroundColor $color
}

Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

# 1. az context
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Write-Result 'az login' 'FAIL' "Run 'az login' first."; exit 1 }
Write-Result 'az login' 'OK' "$($acct.name)"

# 2. RG exists
$rgExists = az group exists --name $ResourceGroup
if ($rgExists -ne 'true') { Write-Result 'Resource group' 'FAIL' "RG '$ResourceGroup' does not exist. Create it (and apply role assignments) first."; exit 1 }
$rgLocation = az group show -n $ResourceGroup --query location -o tsv
Write-Result 'Resource group' 'OK' "$ResourceGroup (location: $rgLocation)"

# 3. RBAC on the RG
$rgScope = "/subscriptions/$($acct.id)/resourceGroups/$ResourceGroup"
$userObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $userObjectId) {
    # Likely a service principal
    $userObjectId = az account show --query user.name -o tsv
    Write-Result 'RBAC check' 'WARN' 'Service-principal context — skipping role check; ensure Contributor + UAA on RG.'
} else {
    $roles = az role assignment list --assignee $userObjectId --scope $rgScope --include-inherited --query "[].roleDefinitionName" -o tsv 2>$null
    $rolesList = if ($roles) { $roles -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
    $hasContrib = ($rolesList | Where-Object { $_ -in @('Owner','Contributor') }).Count -gt 0
    $hasUaa     = ($rolesList | Where-Object { $_ -in @('Owner','User Access Administrator','Role Based Access Control Administrator') }).Count -gt 0
    if ($hasContrib) { Write-Result 'Contributor on RG' 'OK' ($rolesList -join ', ') } else { Write-Result 'Contributor on RG' 'FAIL' "Need Contributor or Owner. Roles seen: $($rolesList -join ', ')"; $failed = $true }
    if ($hasUaa)     { Write-Result 'RBAC Admin on RG' 'OK' } else { Write-Result 'RBAC Admin on RG' 'FAIL' 'Need Owner or "Role Based Access Control Administrator" (for AcrPull role assignment).'; $failed = $true }
}

# 4. Resource provider registration
$requiredRps = @(
    'Microsoft.App',
    'Microsoft.ContainerRegistry',
    'Microsoft.ApiManagement',
    'Microsoft.Network',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.CognitiveServices',
    'Microsoft.Storage',
    'Microsoft.AlertsManagement'
)
$rpStatus = az provider list --query "[?contains(['$($requiredRps -join "','")'], namespace)].{ns:namespace, state:registrationState}" -o json | ConvertFrom-Json
foreach ($rp in $requiredRps) {
    $found = $rpStatus | Where-Object { $_.ns -eq $rp }
    if ($found -and $found.state -eq 'Registered') {
        Write-Result "RP $rp" 'OK'
    } elseif ($AutoRegister) {
        Write-Result "RP $rp" 'WARN' 'registering...'
        az provider register --namespace $rp --only-show-errors | Out-Null
    } else {
        Write-Result "RP $rp" 'FAIL' "Not registered. Run: az provider register --namespace $rp"
        $failed = $true
    }
}

# 5. Region availability — spot-check a few providers in the requested location
$caLocations = az provider show -n Microsoft.App --query "resourceTypes[?resourceType=='containerApps'].locations" -o json 2>$null | ConvertFrom-Json
$locOk = $caLocations | Where-Object { $_ -ieq $Location -or ($_ -replace ' ','') -ieq $Location }
if ($locOk) { Write-Result "Container Apps in $Location" 'OK' } else { Write-Result "Container Apps in $Location" 'FAIL' 'Region not supported.'; $failed = $true }

# 6. GPU quota
if ($CheckGpuQuota) {
    $gpuProfile = 'Consumption-GPU-NC24-A100'
    $profiles = az containerapp env workload-profile list-supported --location $Location -o json 2>$null | ConvertFrom-Json
    $found = $profiles | Where-Object { $_.properties.workloadProfileType -eq $gpuProfile }
    if (-not $found) {
        Write-Result "GPU profile $gpuProfile" 'WARN' "Not advertised in $Location. Verify quota or pick a different region."
    } else {
        Write-Result "GPU profile $gpuProfile" 'OK' "Advertised in $Location."
    }
    # Compute-quota lookup (best effort — name varies by region)
    $skuFamily = 'standardNCADSA100v4Family'  # NC*A100v4 quota family
    $usages = az vm list-usage --location $Location -o json 2>$null | ConvertFrom-Json
    $u = $usages | Where-Object { $_.name.value -eq $skuFamily }
    if ($u) {
        Write-Result "vCPU quota $skuFamily" $(if ($u.limit -gt 0) { 'OK' } else { 'WARN' }) "$($u.currentValue)/$($u.limit) used"
        if ($u.limit -lt 24) { Write-Result "vCPU quota $skuFamily" 'WARN' "Need >= 24 vCPUs for NC24-A100. Request a quota increase if needed." }
    }
}

# 7. Global name collision (best-effort)
$subShort = (([System.Text.RegularExpressions.Regex]::Replace(($acct.id), '[^a-z0-9]', '')) ).Substring(0, [Math]::Min(6, $acct.id.Length))
$candidates = @{
    "contentshieldacr${subShort}"  = 'azurecr.io'
    "csaivllmnfs${subShort}"       = 'file.core.windows.net'
    "cs-ai-contentsafety-${subShort}" = 'cognitiveservices.azure.com'
    "apim-contentshield-${subShort}"  = 'azure-api.net'
}
foreach ($k in $candidates.Keys) {
    $fqdn = "$k.$($candidates[$k])"
    try {
        $null = [System.Net.Dns]::GetHostEntry($fqdn)
        Write-Result "Name $k" 'WARN' "$fqdn resolves — may be taken. Pick a different -NameSuffix if deployment fails."
    } catch {
        Write-Result "Name $k" 'OK' 'free (DNS unresolved)'
    }
}

Write-Host ""
if ($failed) {
    Write-Host "Pre-flight FAILED. Fix the issues above before deploying." -ForegroundColor Red
    exit 1
}
Write-Host "Pre-flight PASSED." -ForegroundColor Green
exit 0
