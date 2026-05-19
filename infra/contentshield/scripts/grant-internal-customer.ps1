#!/usr/bin/env pwsh
<#
.SYNOPSIS
  (VENDOR-side) Grant an internal-Microsoft customer's pipeline identity
  AcrPull on the vendor ACR — the one-shot onboarding for AAD (no token) flow.

.DESCRIPTION
  When the customer's Azure subscription is in the same AAD tenant as your
  vendor ACR (e.g. dogfood, internal MS teams), you can skip scoped tokens
  entirely. The customer's EV2 / ADO service principal (or managed identity)
  pulls directly using AAD.

  This script:
    1. Verifies the supplied object id exists in AAD.
    2. Verifies the vendor ACR exists in the current az subscription.
    3. Creates an 'AcrPull' role assignment scoped to the vendor ACR.
    4. Prints the variables the customer plugs into their pipeline.

  Idempotent — re-running with the same identity is a no-op.

.PARAMETER VendorAcrName
  Vendor ACR name (NOT FQDN), e.g. contentshieldacr.

.PARAMETER CustomerIdentityObjectId
  AAD object id of the customer's pipeline identity. Get this from the
  customer:
    az ad sp show --id <appId-of-their-service-connection> --query id -o tsv

.PARAMETER CustomerName
  Short label used only in console output (e.g. 'dogfood-team').

.PARAMETER PrincipalType
  AAD principal type. Default 'ServicePrincipal' covers ADO service
  connections, managed identities, and federated identities. Use 'User'
  only for direct user-account grants (rare for pipelines).

.EXAMPLE
  .\grant-internal-customer.ps1 `
      -VendorAcrName contentshieldacr `
      -CustomerIdentityObjectId 11111111-2222-3333-4444-555555555555 `
      -CustomerName 'dogfood-platform'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VendorAcrName,
    [Parameter(Mandatory)][string]$CustomerIdentityObjectId,
    [Parameter(Mandatory)][string]$CustomerName,
    [ValidateSet('ServicePrincipal','User','Group')]
        [string]$PrincipalType = 'ServicePrincipal'
)

$ErrorActionPreference = 'Stop'

# ── az context ─────────────────────────────────────────────────────────────
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged into Azure CLI. Run 'az login'." }
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
Write-Host "Tenant:       $($account.tenantId)" -ForegroundColor Green

# ── Verify the vendor ACR ──────────────────────────────────────────────────
$acr = az acr show -n $VendorAcrName -o json 2>$null | ConvertFrom-Json
if (-not $acr) {
    throw "Vendor ACR '$VendorAcrName' not found in subscription '$($account.id)'."
}
Write-Host "Vendor ACR:   $($acr.loginServer)" -ForegroundColor Green

# ── Verify the customer identity exists in AAD ─────────────────────────────
if ($CustomerIdentityObjectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "CustomerIdentityObjectId must be a GUID. Got: $CustomerIdentityObjectId"
}

Write-Host "`nValidating identity $CustomerIdentityObjectId in AAD..." -ForegroundColor Cyan
$identity = $null
switch ($PrincipalType) {
    'ServicePrincipal' {
        $identity = az ad sp show --id $CustomerIdentityObjectId -o json 2>$null | ConvertFrom-Json
    }
    'User' {
        $identity = az ad user show --id $CustomerIdentityObjectId -o json 2>$null | ConvertFrom-Json
    }
    'Group' {
        $identity = az ad group show --group $CustomerIdentityObjectId -o json 2>$null | ConvertFrom-Json
    }
}
if (-not $identity) {
    Write-Warning "Could not resolve $PrincipalType '$CustomerIdentityObjectId' in AAD."
    Write-Warning "Continuing anyway — role assignment will be created but may take effect only after the principal is replicated."
} else {
    $displayName = $identity.displayName ?? $identity.userPrincipalName ?? $CustomerIdentityObjectId
    Write-Host "Identity:     $displayName" -ForegroundColor Green
}

# ── Create the role assignment ─────────────────────────────────────────────
$acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
Write-Host "`nCreating AcrPull role assignment for '$CustomerName' ($CustomerIdentityObjectId) on $VendorAcrName..." -ForegroundColor Cyan

az role assignment create `
    --assignee-object-id $CustomerIdentityObjectId `
    --assignee-principal-type $PrincipalType `
    --role $acrPullRoleId `
    --scope $acr.id `
    --description "AcrPull for internal customer '$CustomerName'" `
    --only-show-errors 2>&1 | Out-Host

# az role assignment create returns non-zero on duplicate. Detect & treat as success.
if ($LASTEXITCODE -ne 0) {
    $existing = az role assignment list `
        --assignee $CustomerIdentityObjectId `
        --scope $acr.id `
        --role $acrPullRoleId `
        --query "[].id" -o tsv 2>$null
    if ($existing) {
        Write-Host "[OK] AcrPull role assignment already exists (idempotent)." -ForegroundColor Yellow
        $LASTEXITCODE = 0
    } else {
        throw "Role assignment creation failed."
    }
} else {
    Write-Host "[OK] AcrPull granted." -ForegroundColor Green
}

# ── Hand-off block — paste to the customer ─────────────────────────────────
Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Onboarded '$CustomerName' (AAD flow)" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Vendor ACR (FQDN):   $($acr.loginServer)" -ForegroundColor Gray
Write-Host "  Customer identity:   $CustomerIdentityObjectId" -ForegroundColor Gray
Write-Host "  Role:                AcrPull" -ForegroundColor Gray
Write-Host ""
Write-Host "  Customer pipeline variables (variable group):" -ForegroundColor Cyan
Write-Host "    vendorAcrFqdn = $($acr.loginServer)"
Write-Host "    useAad        = true"
Write-Host "    # (no vendorAcrTokenName / vendorAcrTokenPassword needed)"
Write-Host ""
Write-Host "  Customer command (smoke test from their subscription):" -ForegroundColor Cyan
Write-Host "    az acr login --name $VendorAcrName --expose-token"
Write-Host ""
