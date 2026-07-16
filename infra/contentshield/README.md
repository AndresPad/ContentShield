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
| 9 | Container App — `ca-ratio-contentshield` | `containerApps.bicep` | **Orchestrator**. Consumption profile, external, IP-allowlist to NAT GW. Routes to the selected Stage-2 via `SLM_ENDPOINT`. |
| 9a | Container App — `ca-cs-stage2-slm` *(mode `slm-gpu` / `both`)* | `stage2App.bicep` | **SLM-GPU** — vLLM (Gemma) on `NC24-A100`, internal ingress IP-allowlist. Baked/offline image — no NFS / HF token needed. |
| 9b | Container App — `ca-cs-stage2-aoai` *(mode `aoai-cpu` / `both`)* | `stage2AoaiApp.bicep` | **AOAI-CPU** — CPU wrapper over an Azure OpenAI gpt-4o deployment. Consumption profile, internal ingress. **No GPU.** |
| 10 | *(optional)* Premium FileStorage + NFS `hfcache` share | `storage.bicep` | `deployStorage=false` by default (the baked slm image needs no NFS). Enable only for a non-baked GPU image. |
| 11 | API Management | `apim.bicep` | StandardV2, VNet External, 30–45 min provision |

All resources use **system-assigned managed identities**. The Container Apps Environment's system MI is automatically granted `AcrPull` on the ACR so container apps pull images via `registries: { identity: 'system-environment' }` (no passwords). The `aoai-cpu` Stage-2 app's MI is granted `Cognitive Services OpenAI User` on the target Azure OpenAI account (by `deploy.ps1` via `-AzureOpenAiResourceId`, cross-RG supported).

## Stage-2 backend selection (the ICM handoff switch)

One parameter, `stage2Mode`, chooses which Stage-2 backend(s) to deploy. Set it in `main.bicepparam` or override with `deploy.ps1 -Stage2Mode <mode>`:

| `stage2Mode` | Deploys | When |
|---|---|---|
| `slm-gpu` | `ca-cs-stage2-slm` only (GPU vLLM/Gemma) | You have A100 GPU quota |
| `aoai-cpu` | `ca-cs-stage2-aoai` only (Azure OpenAI gpt-4o, no GPU) | No GPU quota / cheapest |
| `both` | both, side-by-side | Demo / evaluation RG |
| `none` | no Stage-2 | Orchestrator-only testing |

- **Images** come from three tags in the customer ACR, chosen by `appImageTag`, `slmGpuStage2ImageTag`, and `aoaiCpuStage2ImageTag`. `deploy.ps1` server-side `az acr import`s exactly the tags the selected mode needs from the vendor ACR (`-VendorAcr`, default `ratioaidev.azurecr.io`, AAD auth).
- **Orchestrator routing:** when `both` is deployed, `orchestratorStage2Target` (`slm-gpu` | `aoai-cpu`) picks which Stage-2 the orchestrator calls. Flipping it is a revision-only change.
- **AOAI config:** `azureOpenAiEndpoint` / `azureOpenAiDeployment` / `azureOpenAiApiVersion` point the `aoai-cpu` wrapper at a gpt-4o deployment; the app MI is granted access via `-AzureOpenAiResourceId` (or pass `-AzureOpenAiApiKey` for key auth).

```powershell
# ICM: deploy only the AOAI-CPU Stage-2 against their own Foundry/AOAI account
.\deploy.ps1 -ResourceGroup <rg> -ApimPublisherEmail you@contoso.com `
    -Stage2Mode aoai-cpu -AzureOpenAiResourceId <their-aoai-account-resource-id>

# ICM: deploy only the SLM-GPU Stage-2 (needs A100 quota)
.\deploy.ps1 -ResourceGroup <rg> -ApimPublisherEmail you@contoso.com -Stage2Mode slm-gpu
```

## Naming

| Suffix-applied | Fixed (regional uniqueness) |
|----------------|------------------------------|
| `log-contentshield-<suffix>` | `CONTENTSHIELD-NATGW-PIP` |
| `appi-contentshield-<suffix>` | `CONTENTSHIELD-NATGW-WUS3` |
| `cs-ai-contentsafety-<suffix>` | `NSG-contentshield-westus3` |
| `contentshieldacr<suffix>` (no dash, ACR rules) | `NSG-contentshield-vllm-gpu-subnet-westus3` |
| `cae-contentshield-<suffix>` | `vnet-contentshield-westus3` |
| `apim-contentshield-<suffix>` | `ca-ratio-contentshield` |
| `csaivllmnfs<suffix>` (no dash, storage rules) | `ca-cs-stage2-slm` / `ca-cs-stage2-aoai` |
|  |  |

`nameSuffix` defaults to `take(uniqueString(subscription().id), 6)` — a deterministic 6-char hash of the subscription id, so every customer (and every dev sub) gets globally-unique names with zero configuration. Override via `-NameSuffix <token>` or set `param nameSuffix = '…'` in `main.bicepparam`.

## Quick start

```powershell
# 1. Make sure the RG exists (one-time, with your role assignments)
az group create -n rg-contentshield -l westus3   # only if missing

# 2. (Optional) Create your own replica of the RatioAIDev app registration
.\scripts\create-app-registration.ps1 -DisplayName "ContentShield-Dev"

# 3. Deploy. deploy.ps1 imports the images (by tag) into the new ACR, then
#    wires the container apps — no manual docker push / param edits needed.
#    Pick the Stage-2 backend with -Stage2Mode (default 'both').
.\deploy.ps1 `
    -ResourceGroup rg-contentshield `
    -ApimPublisherEmail you@contoso.com `
    -Stage2Mode aoai-cpu          # or slm-gpu / both

# Fast iteration: add -SkipApim (APIM is the slow part). Add -Reset to wipe the
# RG first (RG + role assignments preserved; soft-deleted APIM/CS are purged).
.\deploy.ps1 -ResourceGroup rg-contentshield -ApimPublisherEmail you@contoso.com -SkipApim
```

## Reset (delete everything inside the RG)

```powershell
.\reset.ps1 -ResourceGroup rg-contentshield                 # interactive
.\deploy.ps1 -ResourceGroup rg-contentshield -Reset ...     # reset + redeploy
```

`reset.ps1` deletes resources in dependency-safe order, waits for APIM deletion to release its subnet, **purges soft-deleted APIM and Cognitive Services accounts** (so a same-name redeploy is not blocked by `ServiceAlreadyExistsInSoftDeletedState`), and then sweeps anything left over. The RG is preserved.

## Configurable parameters (highlights)

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `location` | `westus3` | Keep all resources in WUS3 |
| `nameSuffix` | `icm` | Appended to globally-unique resources |
| `vnetAddressPrefix` | `10.40.0.0/16` | Change if conflicts with peers |
| `gpuWorkloadProfileType` | `Consumption-GPU-NC24-A100` | Use `Consumption-GPU-NC8as-T4` for T4 |
| `stage2Mode` | `both` | `slm-gpu` \| `aoai-cpu` \| `both` \| `none` — which Stage-2 backend(s) to deploy |
| `orchestratorStage2Target` | `aoai-cpu` | When `both` is deployed, which Stage-2 the orchestrator calls |
| `appImageTag` | `1.0.2` | Orchestrator (`contentshield`) tag in the customer ACR |
| `slmGpuStage2ImageTag` | `1.0.3-dev.20260714b-slm-gpu` | SLM-GPU (`contentshield-stage2`) tag |
| `aoaiCpuStage2ImageTag` | `1.0.3-dev.20260715-sdk-retry-aoai-cpu` | AOAI-CPU (`contentshield-stage2`) tag |
| `azureOpenAiEndpoint` | Foundry endpoint | gpt-4o endpoint for the `aoai-cpu` Stage-2 (required for that mode) |
| `azureOpenAiDeployment` | `gpt-4o` | Azure OpenAI deployment name |
| `deployStage2` | `true` | Master off-switch; `false` forces `stage2Mode=none` |
| `deployApim` | `true` | Set false for fast iteration |
| `appImage` / `stage2Image` | mcr quickstart | Placeholder images used before the tag-based import runs |
| `hfToken` | `''` | Hugging Face token (only if a non-baked GPU image downloads at runtime) |
| `deployStorage` | `false` | Create a Premium FileStorage + NFS share (only needed for a non-baked GPU image) |
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

The default `deploy.ps1` flow selects images by **tag** (`appImageTag`,
`slmGpuStage2ImageTag`, `aoaiCpuStage2ImageTag` in `main.bicepparam`) and
imports them for you, so you normally don't set full image references. If you
imported images manually under a different tag, update those tag params (or the
`appImage` / `stage2Image` placeholders) and re-run `.\deploy.ps1`.

## Storage / NFS mount

> Optional — **off by default** (`deployStorage=false`). The `slm-gpu` image is baked/offline and the `aoai-cpu` image has no local model, so neither needs NFS. Enable this only for a non-baked GPU image that downloads its model at runtime.

- When `deployStorage=true`, the bicep deploys `csaivllmnfs<suffix>` as `kind=FileStorage`, `Premium_LRS`, with `allowSharedKeyAccess=false`, `supportsHttpsTrafficOnly=false` (required for NFS 4.1), `largeFileSharesState=Enabled`.
- Public network is restricted to the CAE subnet (`vllm-subnet`) and GPU subnet (`vllm-gpu-subnet`) via `Microsoft.Storage` service endpoints already configured on those subnets.
- A single NFS file share (`hfcache`, 500 GiB, `NoRootSquash`) is created and registered on the CAE as a managed `NfsAzureFile` storage named `hfcache`.
- The GPU Stage-2 app (`ca-cs-stage2-slm`, when configured to mount NFS) uses the share at `/mount/<storageAccountName>/hfcache`; `HF_HOME` is set to the same path automatically.
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
│   ├── containerApps.bicep      # orchestrator (+ legacy single GPU stage-2)
│   ├── stage2App.bicep         # SLM-GPU Stage-2 (mode slm-gpu / variant matrix)
│   ├── stage2AoaiApp.bicep     # AOAI-CPU Stage-2 (mode aoai-cpu)
│   ├── hfPrewarmJob.bicep
│   └── apim.bicep
└── scripts/
    ├── create-app-registration.ps1
    ├── sync-images-from-vendor.ps1   # advanced token/AAD multi-tag import
    ├── export-images.ps1 / import-images.ps1  # offline tarball path
    └── preflight.ps1
```
