# ContentShield — Customer Deployment Guide

A self-contained Bicep template that provisions the full ContentShield workload into **your own** Azure subscription and resource group. Nothing is shared with the vendor's subscription.

> The template **never creates or deletes** your resource group — your role assignments are preserved across redeploys and resets.

---

## 0. What you'll receive from the vendor

| Item | Why |
|------|-----|
| This `infra/contentshield/` folder | Bicep template + scripts |
| `dist/images.zip` (or a `dist/images/` folder) | Tarballed container images |

The images are plain Docker tarballs — no Azure access to the vendor's tenant is needed to use them.

---

## 1. One-time prerequisites

On the machine you'll deploy from:

- **Azure CLI** ≥ 2.55 (`az version`)
- **PowerShell 7+** (`pwsh`)
- **Docker Desktop** (needed only to load the image tarballs)
- **An Azure subscription** with these resource providers registered (the deploy script auto-registers them):
  `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.ApiManagement`, `Microsoft.Network`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.CognitiveServices`, `Microsoft.Storage`, `Microsoft.AlertsManagement`
- **GPU quota** in your chosen region for the workload profile `Consumption-GPU-NC24-A100` (24 vCPU minimum). Request via the Azure portal → Subscriptions → Usage + quotas if missing. Skip with `-SkipStage2` if you don't need GPU yet.

Permissions on the resource group:
- `Contributor` **and** `Role Based Access Control Administrator` (or just `Owner`). RBAC Admin is required because the template creates an `AcrPull` role assignment for the Container Apps Environment.

---

## 2. Create the resource group (once)

```powershell
az login
az account set --subscription <YOUR_SUBSCRIPTION_ID>

# One-time RG creation. The template will NEVER delete this.
az group create -n rg-contentshield -l westus3
```

Apply any organization-specific role assignments / locks / policies to this RG now. The template leaves them alone forever.

---

## 3. Deploy the infrastructure

From inside the `infra/contentshield/` folder:

```powershell
.\deploy.ps1 `
    -ResourceGroup rg-contentshield `
    -ApimPublisherEmail you@yourcompany.com `
    -SkipApim -SkipStage2     # fast first run; drop later
```

What this does:
1. Runs `scripts/preflight.ps1` to verify login, RG, RBAC, resource-provider registration, region, GPU quota, and global name availability.
2. Installs the `containerapp` Azure CLI extension if missing.
3. Deploys all 11 resources in dependency-safe order (Log Analytics → App Insights → Content Safety → Network → ACR → Storage → CAE → Container Apps → APIM).
4. Auto-grants the CAE's system-assigned managed identity `AcrPull` on the new ACR (no passwords for image pulls).

**Naming**: by default `nameSuffix` derives from a 6-char hash of your subscription id, so all globally-unique resources (ACR, storage, content safety, APIM) are unique per customer with **zero configuration**. You can override with `-NameSuffix mychoice` if you want a memorable token (3–8 lowercase alphanumeric).

**Flags**:

| Flag | Effect |
|------|--------|
| `-SkipApim` | Skip APIM (saves 30–45 min during iteration). |
| `-SkipStage2` | Skip the GPU container app (no GPU quota). |
| `-Reset` | Delete everything inside the RG first (RG itself preserved), then redeploy. |
| `-WhatIf` | Show what would happen without changes. |
| `-SkipPreflight` | Skip pre-flight checks (not recommended). |
| `-HfToken <token>` | Pass a Hugging Face token securely (used by stage-2). |

---

## 4. Load container images into your new ACR

**The deployment script does this automatically** when you provide the three vendor-supplied credentials. You do **not** need to download any tarballs.

What you should have received from the vendor:
- `vendorAcrFqdn`         (e.g. `contentshieldacr.azurecr.io`)
- `vendorAcrTokenName`    (e.g. `pull-acme`)
- `vendorAcrTokenPassword` (a long opaque string — **secret**)

Run the deployment with those values appended:

```powershell
.\deploy.ps1 `
    -ResourceGroup rg-contentshield `
    -ApimPublisherEmail you@yourcompany.com `
    -VendorAcrFqdn 'contentshieldacr.azurecr.io' `
    -VendorAcrTokenName 'pull-acme' `
    -VendorAcrTokenPassword '<password from vendor>' `
    -SkipApim     # drop -SkipApim once you're ready for the 30-45 min APIM provision
```

What happens under the hood:
1. **Phase 1** — deploys the full infrastructure (incl. an empty ACR) with placeholder images.
2. **Sync images** — runs `az acr import` server-side to copy the vendor's `contentshield` and `contentshield-stage2` images into your new ACR. Blob-to-blob inside Azure, completes in seconds to a couple of minutes regardless of image size.
3. **Phase 2** — redeploys the container apps pointing at the freshly-imported images. They roll to a new revision automatically.

If you've already imported images another way (offline tarballs, for example), pass `-SkipImageImport` to skip the sync step.

## 5. (Optional) Manual image overrides

If you prefer to pin a specific tag instead of `:latest`, pass `-ImageTag main-20260511-184714` to `deploy.ps1` or set the values directly in `main.bicepparam`:

```bicep
param appImage    = 'contentshieldacr<suffix>.azurecr.io/contentshield:<tag>'
param stage2Image = 'contentshieldacr<suffix>.azurecr.io/contentshield-stage2:<tag>'
```

---

## 6. App registration (optional)

The container apps read `RATIO_AI_DEV_CLIENT_ID` to identify themselves to your AAD app. Create your own replica of the vendor's app registration:

```powershell
.\scripts\create-app-registration.ps1 -DisplayName "ContentShield-Prod"
```

Copy the resulting Client Id into `main.bicepparam`:

```bicep
param ratioAiDevClientId = '<your-new-app-client-id>'
```

Then redeploy.

---

## 7. Reset between iterations

```powershell
.\reset.ps1 -ResourceGroup rg-contentshield                # interactive confirm
.\deploy.ps1 -ResourceGroup rg-contentshield ... -Reset    # reset + redeploy
```

`reset.ps1` deletes resources in dependency-safe order (Container Apps → APIM → CAE → ACR → Cognitive Services [purged] → App Insights → Log Analytics → Storage → VNet → NSGs → NAT GW → Public IP), waits for APIM to release its subnet, and sweeps anything left over. Your resource group, role assignments, locks, and policies are untouched.

---

## 8. Common errors & fixes

| Error | Fix |
|-------|-----|
| `Resource group does not exist` | Run step 2. |
| `AuthorizationFailed` on role assignment | Add `Role Based Access Control Administrator` to your identity on the RG. |
| `SkuNotAvailable: Consumption-GPU-NC24-A100` | Request quota or use a different region; or pass `-SkipStage2`. |
| Storage / ACR / APIM `NameAlreadyExists` | Pass `-NameSuffix <something-unique>` to deploy.ps1. |
| `docker pull/push` 401 | Run `az acr login -n <acrName>` once before the import script. |
| `ConvertFrom-Json: Unexpected character 'B'` | Cosmetic only — the Azure CLI emitted a banner. Deployment likely succeeded; check `az deployment group list -g <rg>`. |

---

## Folder layout

```
infra/contentshield/
├── main.bicep              # orchestrator (targetScope = resourceGroup)
├── main.bicepparam         # parameters (override here or via -Parameters)
├── deploy.ps1              # deploys + runs preflight; flags listed above
├── reset.ps1               # deletes all RG contents (preserves RG)
├── README.md               # vendor-facing developer docs
├── CUSTOMER-README.md      # THIS FILE
├── modules/                # one bicep module per concern
└── scripts/
    ├── preflight.ps1
    ├── export-images.ps1   # vendor uses this
    ├── import-images.ps1   # customer uses this
    └── create-app-registration.ps1
```
