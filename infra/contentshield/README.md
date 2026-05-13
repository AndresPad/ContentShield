# ContentShield — Bicep deployment

End-to-end Bicep template that provisions the ContentShield workload into an **existing** resource group (e.g. `rg-contentshield`).

> 📘 **Shipping this to a customer?** See [CUSTOMER-README.md](./CUSTOMER-README.md) for the end-user guide.

> ⚠️ The resource group itself is **never** created or deleted by these templates. Role assignments on the RG are preserved across resets.

## What gets deployed (in order)

| # | Resource | Module | Notes |
|---|----------|--------|-------|
| 1 | Log Analytics workspace | `monitoring.bicep` | `log-contentshield-<suffix>` |
| 2 | Application Insights | `monitoring.bicep` | workspace-based, `appi-contentshield-<suffix>` |
| 3 | Content Safety | `contentSafety.bicep` | `cs-ai-contentsafety-<suffix>`, S0, system MI |
| 4 | Public IP + NAT Gateway | `network.bicep` | `CONTENTSHIELD-NATGW-PIP` / `…-WUS3` |
| 5 | NSGs (main + GPU subnet) | `network.bicep` | NRMS Core-Security rules baked in |
| 6 | Virtual Network + 3 subnets | `network.bicep` | `vllm-subnet`, `vllm-gpu-subnet`, `vllm-apim-subnet` |
| 7 | Azure Container Registry | `acr.bicep` | `contentshieldacr<suffix>`, Premium, system MI |
| 8 | Container Apps Environment | `containerAppsEnv.bicep` | Workload profiles: `Consumption` + `NC24-A100` GPU |
| 9 | Container App — `ca-ratio-contentshield` | `containerApps.bicep` | Consumption profile, external, IP-allowlist to NAT GW |
| 9 | Container App — `ca-contentshield-stage2` | `containerApps.bicep` | **GPU** (`NC24-A100`), internal, ingress IP-allowlist (NAT GW + CAE static IP + optional extras), NFS mount at `/mount/<storage>/hfcache` |
| 10 | Premium FileStorage account + NFS `hfcache` share | `storage.bicep` | `csaivllmnfs<suffix>`, FileStorage / Premium_LRS, OAuth-only, VNet-restricted to CAE + GPU subnets |
| 11 | API Management | `apim.bicep` | StandardV2, VNet External, 30–45 min provision |

All resources use **system-assigned managed identities**. The Container Apps Environment's system MI is automatically granted `AcrPull` on the ACR so container apps pull images via `registries: { identity: 'system-environment' }` (no passwords).

## Naming

| Suffix-applied | Fixed (regional uniqueness) |
|----------------|------------------------------|
| `log-contentshield-<suffix>` | `CONTENTSHIELD-NATGW-PIP` |
| `appi-contentshield-<suffix>` | `CONTENTSHIELD-NATGW-WUS3` |
| `cs-ai-contentsafety-<suffix>` | `NSG-contentshield-westus3` |
| `contentshieldacr<suffix>` (no dash, ACR rules) | `NSG-contentshield-vllm-gpu-subnet-westus3` |
| `cae-contentshield-<suffix>` | `vnet-contentshield-westus3` |
| `apim-contentshield-<suffix>` | `ca-ratio-contentshield` |
| `csaivllmnfs<suffix>` (no dash, storage rules) | `ca-contentshield-stage2` |
|  |  |

`nameSuffix` defaults to `take(uniqueString(subscription().id), 6)` — a deterministic 6-char hash of the subscription id, so every customer (and every dev sub) gets globally-unique names with zero configuration. Override via `-NameSuffix <token>` or set `param nameSuffix = '…'` in `main.bicepparam`.

## Quick start

```powershell
# 1. Make sure the RG exists (one-time, with your role assignments)
az group create -n rg-contentshield -l westus3   # only if missing

# 2. (Optional) Create your own replica of the RatioAIDev app registration
.\scripts\create-app-registration.ps1 -DisplayName "ContentShield-Dev"

# 3. First deploy (skip APIM + GPU for fastest iteration)
.\deploy.ps1 `
    -ResourceGroup rg-contentshield `
    -ApimPublisherEmail you@contoso.com `
    -SkipApim -SkipStage2

# 4. Push your container images to the new ACR, then update main.bicepparam
#    (appImage / stage2Image) and re-run without -SkipApim / -SkipStage2.
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com
```

## Reset (delete everything inside the RG)

```powershell
.\reset.ps1 -ResourceGroup rg-contentshield                 # interactive
.\deploy.ps1 -ResourceGroup rg-contentshield -Reset ...     # reset + redeploy
```

`reset.ps1` deletes resources in dependency-safe order, waits for APIM deletion to release its subnet, purges soft-deleted Cognitive Services accounts, and then sweeps anything left over. The RG is preserved.

## Configurable parameters (highlights)

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `location` | `westus3` | Keep all resources in WUS3 |
| `nameSuffix` | `icm` | Appended to globally-unique resources |
| `vnetAddressPrefix` | `10.40.0.0/16` | Change if conflicts with peers |
| `gpuWorkloadProfileType` | `Consumption-GPU-NC24-A100` | Use `Consumption-GPU-NC8as-T4` for T4 |
| `deployStage2` | `true` | Set false if no GPU quota |
| `deployApim` | `true` | Set false for fast iteration |
| `appImage` / `stage2Image` | mcr quickstart | Replace with your ACR images |
| `hfToken` | `''` | Hugging Face token for stage-2 model download |
| `deployStorage` | `true` | Create a Premium FileStorage replica of `ratioaivllmnfs` in this RG |
| `storageAccountName` | `csaivllmnfs<suffix>` | Override only if you need a specific name |
| `hfCacheShareName` / `hfCacheShareQuotaGiB` | `hfcache` / `500` | NFS share name and quota |
| `nfsServer` / `nfsShareName` | `''` | Only used when `deployStorage = false` (point at an external account) |
| `extraStage2AllowedIps` | `[]` | Append e.g. the stage-2 outbound IP after the first deploy |
| `ratioAiDevClientId` | `aceb273b-…ff92e9` | Your replica app reg id |

## Copy images from the existing ACR (`contentshieldacr`)

### Option A — Ship images to a customer (offline, no shared subscription)

This is the path to use when the customer has **no access to your subscription**.

**On your machine** (needs Docker Desktop + AcrPull on `contentshieldacr`):

```powershell
# Pull each repo:tag from your ACR and save as a .tar file under .\dist\images\
.\scripts\export-images.ps1 -Compress
```

This produces:
```
dist\images\contentshield_<tag>.tar
dist\images\contentshield-stage2_<tag>.tar
dist\images\manifest.json
dist\images.zip          # if you passed -Compress
```

Ship the `dist\images\` folder (or the `.zip`) to the customer through any
secure file transfer — these are plain Docker image tarballs, no Azure access
required to use them.

**On the customer machine** (after the bicep deploy has created their new ACR):

```powershell
# Loads tarballs, retags for the customer's ACR, and pushes
.\scripts\import-images.ps1 `
    -TargetAcrName <theirAcrName> `
    -FromTarballDir <pathToImagesFolder>
```

The script reads `manifest.json`, runs `docker load`, retags to
`<theirAcr>.azurecr.io/contentshield:<tag>` + `:latest`, and pushes.

### Option B — Direct ACR-to-ACR import (same tenant / shared access)

Use this when **you** are also the one deploying into the customer's RG and
you have AcrPush on the target plus AcrPull on the source. Server-side copy,
no local docker needed:

```powershell
.\scripts\import-images.ps1 -TargetAcrName contentshieldacricm
# or a specific tag
.\scripts\import-images.ps1 -TargetAcrName contentshieldacricm -Tag main-20260511-184714
# cross-subscription source
.\scripts\import-images.ps1 -SourceAcrName contentshieldacr `
    -SourceSubscription "01819f01-7af1-4dd8-9354-9dccc163ceae" `
    -TargetAcrName contentshieldacricm
```

### After either option

Set the image references in `main.bicepparam`:

```bicep
param appImage    = 'contentshieldacricm.azurecr.io/contentshield:latest'
param stage2Image = 'contentshieldacricm.azurecr.io/contentshield-stage2:latest'
```

Then re-run `.\deploy.ps1` to roll the new images into the container apps.

## Storage / NFS mount- The bicep deploys `csaivllmnfs<suffix>` as `kind=FileStorage`, `Premium_LRS`, with `allowSharedKeyAccess=false`, `supportsHttpsTrafficOnly=false` (required for NFS 4.1), `largeFileSharesState=Enabled`.
- Public network is restricted to the CAE subnet (`vllm-subnet`) and GPU subnet (`vllm-gpu-subnet`) via `Microsoft.Storage` service endpoints already configured on those subnets.
- A single NFS file share (`hfcache`, 500 GiB, `NoRootSquash`) is created and registered on the CAE as a managed `NfsAzureFile` storage named `hfcache`.
- `ca-contentshield-stage2` mounts the share at `/mount/<storageAccountName>/hfcache`; `HF_HOME` is set to the same path automatically.
- Sample VM mount command (from any host on an allowed subnet):
  ```bash
  sudo mkdir -p /mount/csaivllmnfsicm/hfcache
  sudo mount -t aznfs csaivllmnfsicm.file.core.windows.net:/csaivllmnfsicm/hfcache \
      /mount/csaivllmnfsicm/hfcache -o vers=4,minorversion=1,sec=sys,nconnect=4
  ```

## Folder layout

```
infra/contentshield/
├── main.bicep              # orchestrator (targetScope = resourceGroup)
├── main.bicepparam         # default parameters; edit before deploy
├── deploy.ps1              # deploy + optional -Reset / -WhatIf
├── reset.ps1               # safe RG-content deletion (preserves RG)
├── modules/
│   ├── monitoring.bicep
│   ├── contentSafety.bicep
│   ├── network.bicep
│   ├── storage.bicep
│   ├── acr.bicep
│   ├── containerAppsEnv.bicep
│   ├── containerApps.bicep
│   └── apim.bicep
└── scripts/
    └── create-app-registration.ps1
```
