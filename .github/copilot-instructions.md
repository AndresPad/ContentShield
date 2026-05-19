# ContentShield — Copilot Instructions

This repository contains **only Azure infrastructure-as-code** (Bicep + PowerShell) for the ContentShield workload. There is no application source here — container images are produced elsewhere and pulled from ACR. Everything lives under `infra/contentshield/`.

## Layout

```
infra/contentshield/
├── main.bicep              # orchestrator, targetScope = resourceGroup
├── main.bicepparam         # default parameter values
├── deploy.ps1              # entry point: az deployment group create + optional reset/image import
├── reset.ps1               # deletes all resources in the RG (RG itself preserved)
├── modules/                # one bicep module per resource family
│   ├── monitoring.bicep    # Log Analytics + App Insights
│   ├── contentSafety.bicep
│   ├── network.bicep       # Public IP, NAT GW, NSGs, VNet + 3 subnets
│   ├── storage.bicep       # Premium FileStorage + NFS hfcache share
│   ├── acr.bicep
│   ├── containerAppsEnv.bicep   # CAE with Consumption + NC24-A100 profiles
│   ├── containerApps.bicep      # ca-ratio-contentshield + ca-contentshield-stage2
│   └── apim.bicep
└── scripts/                # operational helpers (image transfer, preflight, app reg, tokens)
```

`README.md` (operator-facing) and `CUSTOMER-README.md` (end-user packaging) and `SYSTEM_DESIGN.md` (target product architecture — *not* implemented in this repo) are in `infra/contentshield/`.

## Deploy / reset commands

All commands assume `cwd = infra/contentshield/` and an existing RG (the RG is **never** created or deleted by these scripts; role assignments on it are preserved).

```powershell
# Standard deploy
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com

# Fast iteration (skip the 30-45 min APIM and the GPU app)
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com -SkipApim -SkipStage2

# What-if (no changes applied)
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com -WhatIf

# Reset + redeploy in one go
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com -Reset

# Reset only (interactive confirmation)
.\reset.ps1 -ResourceGroup rg-contentshield
```

There is no test or lint suite. To validate Bicep changes without deploying:

```powershell
az bicep build --file main.bicep              # syntactic + type check
.\deploy.ps1 ... -WhatIf                       # full resolution against Azure
```

`deploy.ps1` runs `scripts\preflight.ps1` first (resource providers, GPU quota, permissions). Pass `-SkipPreflight` only when intentionally bypassing it.

## Two-phase deployment with vendor image import

When `-VendorAcrFqdn` / `-VendorAcrTokenName` / `-VendorAcrTokenPassword` are supplied to `deploy.ps1`:

1. **Phase 1** deploys infra with the default `mcr.microsoft.com/k8se/quickstart:latest` placeholder images so the container apps come up immediately.
2. `scripts\sync-images-from-vendor.ps1` copies real images from the vendor ACR into the customer ACR.
3. **Phase 2** redeploys, overriding `appImage` / `stage2Image` to point at `<customerAcr>.azurecr.io/contentshield(-stage2):<tag>`.

When editing `deploy.ps1`, preserve this two-phase pattern — container apps must be able to deploy before customer images exist.

## Key conventions

- **`nameSuffix`** is the linchpin of multi-tenant naming. It defaults to `take(uniqueString(subscription().id), 6)` so every subscription gets globally-unique names with zero configuration. Resources split into two groups:
  - Suffix-applied (globally-unique services): `log-…-<suffix>`, `appi-…-<suffix>`, `cs-ai-contentsafety-<suffix>`, `contentshieldacr<suffix>` (no dash — ACR rules), `cae-…-<suffix>`, `apim-…-<suffix>`, `csaivllmnfs<suffix>` (no dash — storage rules).
  - Fixed names (only regional uniqueness needed): `CONTENTSHIELD-NATGW-PIP`, `CONTENTSHIELD-NATGW-WUS3`, `NSG-…`, `vnet-contentshield-westus3`, `ca-ratio-contentshield`, `ca-contentshield-stage2`.
- **Managed identity everywhere.** Every resource that supports it uses a system-assigned MI. The CAE's system MI is granted `AcrPull` on the ACR, and container apps reference the registry via `registries: { identity: 'system-environment' }` — **never embed ACR usernames/passwords**.
- **Image pulls** for container apps must continue to use the environment-level system MI. If you add a new container app, make sure the CAE→ACR `AcrPull` role assignment covers it (no per-app credentials).
- **GPU app (`ca-contentshield-stage2`)**: internal ingress only, runs on the `NC24-A100` workload profile, mounts the `hfcache` NFS share at `/mount/<storageAccountName>/hfcache`, and sets `HF_HOME` to that path. `extraStage2AllowedIps` is appended to its ingress allowlist — after first deploy, append the app's own outbound IP (visible via `az containerapp show ... --query properties.outboundIpAddresses`) and redeploy.
- **Storage NFS**: `kind=FileStorage`, `Premium_LRS`, `allowSharedKeyAccess=false`, `supportsHttpsTrafficOnly=false` (required for NFS 4.1), `largeFileSharesState=Enabled`. Public access restricted via `Microsoft.Storage` service endpoints on `vllm-subnet` and `vllm-gpu-subnet`. Keep these flags when modifying `modules/storage.bicep`.
- **`reset.ps1` ordering matters.** It deletes in a dependency-safe order, waits for APIM to release its subnet, purges soft-deleted Cognitive Services accounts, then sweeps remainders. When adding new resource types, slot them into the correct dependency tier rather than appending blindly.
- **NSG rules** include hard-coded NRMS Core-Security rules in `modules/network.bicep`. Don't strip these when adding new rules.
- **Secrets** (`hfToken`, vendor ACR token password) flow through PowerShell `[string]` params into Bicep `@secure()` parameters via `--parameters key=value` on `az deployment group create`. Never hard-code into `main.bicepparam`.
- **Bicep param overrides** in `deploy.ps1` are passed as additional `--parameters key=value` pairs *after* `--parameters main.bicepparam`, so they override file values. Preserve this ordering.

## Where things actually live vs. SYSTEM_DESIGN.md

`SYSTEM_DESIGN.md` describes the *product* (orchestrator + regex/ACS/Linear/SLM/LLM detectors, `POST /v1/detect`, modes `fast`/`standard`/`deep`). **None of that application code is in this repo** — only the Azure infra those services run on. When changes are requested, confirm whether the user means infra (this repo) or the application (different repo).
