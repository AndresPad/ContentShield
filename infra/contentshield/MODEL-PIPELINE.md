# Stage-2 Model Pipeline — Design Document

> **Scope.** Two coupled questions that have been hand-waved so far:
>   1. **How do model weights get from us (vendor) into each customer's NFS share?**
>   2. **Target shape of the stage-2 Dockerfile** (item #9 in our backlog).
>
> Status: design-only. No infra is being changed by this document.

---

## 1. Current reality (be honest about what we have)

```
huggingface.co  ─►  customer NFS share  ─►  vLLM mmap  ─►  GPU
   (public)         (Premium_LRS)            (mount)        (NC24-A100)
```

That's it. There is **no vendor → customer model distribution today.** At first run, vLLM (invoked from [`start-vllm.sh`](RatioAI.ContentShield/services/stage2/deploy/scripts/start-vllm.sh) with `--model $MODEL_NAME` and `HF_HOME=/mnt/hfcache`) downloads from the public HF Hub straight into the NFS share. The optional prewarm Container Apps Job we just added ([`hfPrewarmJob.bicep`](infra/contentshield/modules/hfPrewarmJob.bicep)) does the same `huggingface-cli download` ahead of time so the first request doesn't pay the cold-start cost — but the source is still HF Hub.

The "vendor NFS" mentioned in the question (`ratioaivllmnfs` in `rg-ratio-ai-dev`) is **our development cache** — it is never read by a customer, and structurally cannot be (NFS does not work cross-tenant, and even cross-subscription requires VNet peering we never set up).

### Container image layout already in place

The stage-2 service is **two images, not one**:

| Image | Built where | Contents | Change frequency |
|---|---|---|---|
| `ratioaidev.azurecr.io/contentshield-stage2:v1` (base) | Vendor pipeline, **not in this repo** | CUDA + vLLM + Python deps | Rare (vLLM/CUDA bumps) |
| `ratioaidev.azurecr.io/contentshield-stage2:v2`+ (overlay) | [`services/stage2/Dockerfile`](RatioAI.ContentShield/services/stage2/Dockerfile), `FROM ${BASE_IMAGE}` | `src/stage2`, prompts, `start-vllm.sh` | Every code patch |

The orchestrator ([`Dockerfile`](RatioAI.ContentShield/Dockerfile)) is its own tiny image (`python:3.11-slim` + `uv sync`) — no GPU, no weights.

This split is good: the heavy base image is built once and reused; only the small overlay rebuilds on code changes. Any redistribution design has to **preserve** this structure, not collapse it.

**Consequences of the current model:**

| Risk | Impact |
|---|---|
| HF Hub takes a model down or rotates a commit | All customer cold starts of that version break. |
| HF Hub blocked in customer environment (sovereign cloud, MS-internal compliance) | Customer cannot deploy. |
| HF rate-limits the customer | Pre-warm fails on first deploy. |
| We ship a private fine-tune that doesn't exist on HF | No distribution path at all. |
| Same `imageTag` deployed today vs. 6 months from now | May get different weights. **Not reproducible.** |
| Vendor wants to audit which weights any given customer is running | Impossible — no central record. |

This is the gap. The rest of this document is about fixing it.

---

## 2. Distribution options — honest comparison

### A. Status quo: each customer pulls from huggingface.co

```
HF Hub ──https──► customer prewarm job ──write──► customer NFS
```

| | |
|---|---|
| Pros | Zero work. |
| Cons | All the risks in §1. |
| Best for | Demos and internal experiments. |

### B. Vendor blob (Standard hot) + customer prewarm pulls via SAS or AAD

```
Vendor blob ──https──► customer prewarm job ──write──► customer NFS
```

| | |
|---|---|
| Pros | Cheap (~$0.02/GiB-month). Versioned. AAD or SAS-scoped per customer. |
| Cons | New auth path (different from ACR). Two credentials to manage per customer (ACR + blob). Cross-tenant SAS requires care. Public-internet path unless we wire private endpoints + customer VNet peering. |
| Best for | Mass distribution to many external customers with low coupling. |

### C. Vendor ACR + ORAS artifact + customer ACR + `oras copy`

```
Vendor ACR (ORAS artifact)  ──oras copy──►  Customer ACR (same artifact)  ──oras pull──►  prewarm job  ──write──►  customer NFS
```

| | |
|---|---|
| Pros | **Reuses the auth path we already built** (vendor ACR scoped tokens / AAD AcrPull). One distribution channel for images AND weights. ORAS supports attaching weights as a *referrer* to the stage-2 image — promoting `stage2:1.4.0` automatically promotes its weights. Versioned. Auditable (manifest digest). Idempotent (`oras copy` is content-addressed). |
| Cons | Customer prewarm job needs the `oras` CLI (small, single binary). `az acr import` does NOT copy ORAS artifacts — customer pipeline calls `oras copy` instead (or in addition). Untar step needed on the customer side. |
| Best for | What we're already doing. **This is the recommendation.** |

### D. Bake weights into the stage-2 image as a dedicated layer (item #9)

```
Build  ──►  vendor ACR  ──az acr import──►  customer ACR  ──ACA pull (streamed)──►  GPU node local SSD
```

| | |
|---|---|
| Pros | Zero distribution machinery beyond what we already have. Atomic — image and weights versioned together, no skew. Sub-60s replica start with artifact streaming. |
| Cons | 20-30 GB image. Every code change rebuilds. New replicas pull on every new node (no shared cache). Less flexible if model needs to change without code change. |
| Best for | Production cold-start performance, fewer than ~100 customers. |

### E. Hybrid (D + C) — recommended end state

```
Stage-2 image (small, code only)  ──►  customer ACR  ──►  GPU app  ─┐
                                                                    ├──►  reads weights from NFS, populated from customer ACR ORAS artifact
ORAS weights artifact (big)        ──►  customer ACR  ──►  prewarm ─┘
```

- Code and weights versioned together by **convention** (same `:1.4.0` tag, different OCI media types) and verified by **referrer link** in the manifest.
- One registry, one auth, two artifact kinds.
- Stage-2 image stays small → fast code-only deploys.
- Weights pinned to a digest the vendor controls → no HF Hub at runtime.

This is the architecture this document recommends.

---

## 3. Recommended architecture (option E in detail)

### 3.1 Vendor side

For each model version `m`:

```
oras push contentshieldacr.azurecr.io/contentshield-stage2-weights:1.4.0 \
    --artifact-type application/vnd.contentshield.model.v1+tar \
    ./weights.tar.gz:application/vnd.contentshield.model.v1.layer+gzip

# Attach as a referrer to the runtime image (optional but elegant):
oras attach contentshieldacr.azurecr.io/contentshield-stage2:1.4.0 \
    --artifact-type application/vnd.contentshield.model.v1+tar \
    ./weights.tar.gz:application/vnd.contentshield.model.v1.layer+gzip
```

`weights.tar.gz` is the entire HF cache tree (`models--<org>--<name>/...`) tarred up. Use `pigz` or `--use-compress-program=zstd` for parallel compression. Typical sizes:

| Model | FP16 size | tar.gz |
|---|---|---|
| `google/gemma-4-31b-it` | ~62 GB | ~30 GB |
| `meta-llama/Llama-3.1-8B-Instruct` | ~16 GB | ~8 GB |

Then lock the tag (same pattern as our image publishing):

```bash
az acr repository update \
    --name contentshieldacr \
    --image contentshield-stage2-weights:1.4.0 \
    --write-enabled false \
    --delete-enabled false
```

We extend [scripts/publish-image.ps1](infra/contentshield/scripts/publish-image.ps1) to optionally accept `-WeightsTarPath` and run the ORAS push + attach + lock automatically.

### 3.2 Customer side

Customer pipeline (extension of [pipelines/azure-pipelines.customer.yml](infra/contentshield/pipelines/azure-pipelines.customer.yml)):

```yaml
- task: AzureCLI@2
  displayName: 'Copy weights ORAS artifact (vendor ACR → customer ACR)'
  inputs:
    scriptType: bash
    inlineScript: |
      # Install oras (single binary).
      curl -LO https://github.com/oras-project/oras/releases/download/v1.2.3/oras_1.2.3_linux_amd64.tar.gz
      tar -xzf oras_*.tar.gz oras
      ./oras version

      # Login to BOTH registries (oras supports the same AAD token as az acr).
      az acr login --name $(vendorAcrName) --expose-token --output tsv --query accessToken \
        | ./oras login $(vendorAcrFqdn) -u 00000000-0000-0000-0000-000000000000 --password-stdin
      az acr login --name $(customerAcrName) --expose-token --output tsv --query accessToken \
        | ./oras login $(customerAcrFqdn) -u 00000000-0000-0000-0000-000000000000 --password-stdin

      # Server-side, content-addressed copy (skips blobs the customer ACR already has).
      ./oras copy \
        $(vendorAcrFqdn)/contentshield-stage2-weights:$(imageTag) \
        $(customerAcrFqdn)/contentshield-stage2-weights:$(imageTag)
```

Then the prewarm job (replacement for the current HF Hub call): the same Container Apps Job we already build, but with a different entrypoint script:

```bash
# Inside the prewarm container:
oras pull "$CUSTOMER_ACR_FQDN/contentshield-stage2-weights:$IMAGE_TAG" -o /tmp/weights
tar -xzf /tmp/weights/weights.tar.gz -C "$HF_HOME"
```

The prewarm Bicep module ([modules/hfPrewarmJob.bicep](infra/contentshield/modules/hfPrewarmJob.bicep)) gains a `modelSource` param (`huggingface` | `acr-oras`) that picks the script. Auth into customer ACR uses the **same job MI** — already granted `AcrPull` via the CAE storage path. No new credentials.

### 3.3 Stage-2 GPU app

No change. It still mounts the NFS share at `HF_HOME` and mmap's normally. It doesn't know or care where the cache came from.

### 3.4 What this gives us

| Property | How it's achieved |
|---|---|
| **No HF Hub at runtime** | Customer prewarm pulls from customer ACR only. |
| **Same auth as images** | ORAS uses the ACR's AAD/token auth. Already wired. |
| **Reproducible** | `oras copy` is digest-preserving. Tag `:1.4.0` always points at the same blob, in every customer's registry, forever. |
| **Auditable** | Every customer's `customerAcr/contentshield-stage2-weights:1.4.0` has the same digest as the vendor's. We can prove it. |
| **One distribution channel** | Customer pipeline learns one new step (`oras copy`); everything else unchanged. |
| **Bandwidth-efficient** | Server-side blob copy between two Azure ACRs — never traverses the customer's pipeline runner. |
| **NFS still shared across replicas** | Stage-2 reads from NFS the same way it does today. |

### 3.5 Migration path

1. **Now:** vendor publishes both `contentshield-stage2:1.4.0` (image) and `contentshield-stage2-weights:1.4.0` (ORAS artifact). Customers continue to use HF Hub — nothing breaks.
2. **Next deploy cycle:** customer pipeline gains the `oras copy` step. Prewarm Bicep param flips to `modelSource=acr-oras`. HF Hub dependency is removed.
3. **Cutover:** customers no longer need `huggingface.co` reachable. We delete the HF-Hub code path from the prewarm job.
4. **(Later)** evolve to option D (image-baked weights) for the sub-60s cold-start cohort.

---

## 4. Stage-2 Dockerfile design (item #9, corrected)

The original framing of #9 — "refactor the stage-2 Dockerfile to put weights in their own layer" — assumed one monolithic Dockerfile. Looking at the actual sources ([`services/stage2/Dockerfile`](RatioAI.ContentShield/services/stage2/Dockerfile)), the work is already partially done: there are **two images** (base + app overlay), and we should preserve that split rather than collapse it. This section describes the actual delta needed for each redistribution option.

### 4.1 What we keep (don't touch)

The app overlay Dockerfile is correct as-is:

```dockerfile
ARG BASE_IMAGE=ratioaidev.azurecr.io/contentshield-stage2:v1
FROM ${BASE_IMAGE}

ARG EXTRA_PIP_PACKAGES=""
RUN if [ -n "$EXTRA_PIP_PACKAGES" ]; then python3 -m pip install --no-cache-dir $EXTRA_PIP_PACKAGES; fi

WORKDIR /workspace
COPY src/stage2 /workspace/stage2
COPY prompts/pi-classifier-v6.txt /workspace/prompts/pi-classifier-v6.txt
COPY prompts/pi-reason-v1.txt    /workspace/prompts/pi-reason-v1.txt
COPY deploy/scripts/start-vllm.sh /workspace/scripts/start-vllm.sh
...
ENTRYPOINT ["/workspace/scripts/start-vllm.sh"]
```

Good properties already present:
- `ARG BASE_IMAGE` → version of CUDA/vLLM is pinned by tag; bump independently from the app.
- App layer is tiny → fast rebuilds, fast pulls, fast revisions in ACA.
- `start-vllm.sh` reads `HF_HOME` → weights source is **transparent** to the runtime. NFS mount, baked layer, or empty cache (live HF download) all work without code changes.

This means **no edits are required to the existing overlay Dockerfile** for options B, C, or even E.

### 4.2 Recommended addition: dedicated `-baked` Dockerfile (only for option D)

For the cohort that wants sub-60s cold starts and is willing to accept a 30 GB image, add a third Dockerfile alongside the existing one:

```dockerfile
# services/stage2/Dockerfile.baked
# Weights-baked variant. Produces contentshield-stage2-baked:<ver> on top of
# the already-published overlay image.
#
# Build:
#   oras pull <vendorAcr>/contentshield-stage2-weights:<ver> -o ./_weights
#   az acr build -r contentshieldacr \
#       -t contentshield-stage2-baked:<ver> \
#       -f services/stage2/Dockerfile.baked \
#       --build-arg APP_IMAGE=contentshieldacr.azurecr.io/contentshield-stage2:<ver> \
#       services/stage2
ARG APP_IMAGE
FROM ${APP_IMAGE}

# The ENTIRE Dockerfile is one COPY. The blob is its own OCI layer; ACR
# artifact streaming fetches it lazily. Code-only patches rebuild only the
# app image, never this one.
COPY _weights/ /mnt/hfcache/
ENV HF_HOME=/mnt/hfcache
```

Three reasons this is small:

1. The base + app layers are already published — `APP_IMAGE` is just a parent reference, no re-bake.
2. Weights are downloaded **outside the Docker build** via `oras pull` (from the vendor ACR), so we don't need `HF_TOKEN` or `hf_transfer` inside the build context.
3. The final image has exactly **one** new OCI layer relative to the app image: the weights blob. That's the property ACR artifact streaming optimizes for.

Why not download via `huggingface-cli` inside the build? Because the build is already running in ACR Tasks; pulling from another tag in the same ACR (via `oras`) is faster, content-addressed, and avoids a build-time HF Hub dependency. The weights are versioned in our registry exactly once.

### 4.3 Why not bake into the existing overlay Dockerfile?

Tempting (one fewer file). Don't:

| Risk | Why it matters |
|---|---|
| Every code patch invalidates the weights layer if it's in the same Dockerfile | Code rebuilds are seconds; weight rebuilds are tens of minutes. Don't couple them. |
| Some customers want the slim overlay + NFS (option B/C); some want baked (option D) | Two Dockerfiles = two image variants, customers pick. One Dockerfile with `ARG WITH_WEIGHTS=false` = build matrix complexity. |
| `start-vllm.sh` already reads `HF_HOME` cleanly | The baked variant just sets `HF_HOME=/mnt/hfcache` and pre-populates it. No code change to honor it. |

### 4.4 Build/publish flow with the `-baked` variant

```powershell
# 1) Pull weights from vendor ACR into a local staging dir.
oras pull contentshieldacr.azurecr.io/contentshield-stage2-weights:1.4.0 `
          -o ./services/stage2/_weights

# 2) Server-side build in ACR Tasks.
az acr build -r contentshieldacr `
    -t contentshield-stage2-baked:1.4.0 `
    -f services/stage2/Dockerfile.baked `
    --build-arg APP_IMAGE=contentshieldacr.azurecr.io/contentshield-stage2:1.4.0 `
    ./services/stage2

# 3) Lock the tag (re-use publish-image.ps1's lock step or open-code it).
```

Later we extend [`publish-image.ps1`](infra/contentshield/scripts/publish-image.ps1) with a `-WithWeights` switch that does steps 1–3 automatically when `contentshield-stage2-weights:<ver>` already exists in the vendor ACR.

### 4.5 Where this leaves NFS

NFS is still required for **options B and C** (the recommendation): the prewarm job untars the ORAS-distributed weights into the share; vLLM mmap's them at runtime; all GPU replicas share one copy.

NFS is **optional** for **option D** (baked): each replica has its own copy on local SSD. The customer can set `deployStorage=false` and skip `hfPrewarmJob.bicep` entirely. Smaller blast radius, simpler infra.

A pragmatic policy: ship both. Default is option C (NFS + ORAS prewarm). A `weightsInImage=true` switch in [containerApps.bicep](infra/contentshield/modules/containerApps.bicep) flips to the `-baked` image and skips the NFS mount.

---

## 5. Concrete next actions, in order

| Order | Action | Owner | Status | Unblocks |
|---|---|---|---|---|
| 1 | New script [`publish-weights.ps1`](infra/contentshield/scripts/publish-weights.ps1) — `oras push` of `contentshield-stage2-weights:<tag>` to the vendor ACR, with `-AttachToImage` for the referrer link. | Us | **Done** | Vendor can publish weights as an OCI artifact. |
| 2 | Add `oras copy` step to [customer pipeline template](infra/contentshield/pipelines/azure-pipelines.customer.yml). | Us | Open | Customer pipeline can promote weights vendor ACR → customer ACR. |
| 3 | Add `modelSource=acr-oras` mode to [hfPrewarmJob.bicep](infra/contentshield/modules/hfPrewarmJob.bicep) + the embedded script (replace `huggingface-cli download` with `oras pull` + untar). | Us | Open | Prewarm pulls weights from customer ACR instead of HF Hub. |
| 4 | Cut over a single internal customer end-to-end. Verify cold-start metrics. | Us + 1 customer | Open | Validates the path before broad rollout. |
| 5 | Add `services/stage2/Dockerfile.baked` (§4.2) + extend `publish-image.ps1` with `-WithWeights` switch. | Us (vendor pipeline) | Open (optional) | Produces the `contentshield-stage2-baked:<ver>` variant for option D. |
| 6 | Add a `weightsInImage` switch to [containerApps.bicep](infra/contentshield/modules/containerApps.bicep) — when true, skip the NFS mount and prewarm job, point app at `contentshield-stage2-baked` tag. | Us | Open (optional) | Customers can opt into image-baked weights once #5 ships. |

Steps 1–4 are unblocked today. Steps 5–6 are an opt-in cohort feature, not a blocker for the redistribution work.

**Note on the existing app overlay Dockerfile.** It does not need changes (§4.1). The previously-planned "refactor stage-2 Dockerfile to put weights in their own layer" item is **resolved** by the base/overlay split that's already in place; the only remaining work is the new `Dockerfile.baked` variant, which is opt-in.

---

## 6. What this document does NOT decide

- Whether to use ORAS referrers (`oras attach`) vs. a sibling repo. Both work; referrers are slightly more elegant but require ORAS ≥ 1.1 and OCI 1.1 — pick at implementation time.
- Whether to compress weights with `gzip`, `zstd`, or store uncompressed. `zstd -3` is the sweet spot for HF weights (∼1.4x faster decompress than gzip, similar ratio). Decide when implementing step 1.
- Whether to delete `modules/storage.bicep` after #7 lands. Recommend keeping it as `deployStorage=false` default for one release cycle for rollback safety.
- The customer-side handling of multiple model variants (e.g. INT8 vs FP16). Single-tag-per-version is enough until we actually have variants.
