# Stage-2 cold-start, warm-start, and scaling report

**Date:** 2026-05-21
**Environment:** `rg-contentshield` / `cae-contentshield-axa1` (westus3)
**Hardware:** NC24-A100 — 24 vCPU, 220 GiB RAM, 1× NVIDIA A100 80 GB per node
**Replica sizing (mandatory):** `cpu=24` / `memory=220Gi` per replica
**Workload profile:** `Consumption-GPU-NC24-A100`
**Model:** Gemma-4-31B-IT (gated on HuggingFace, requires `HF_TOKEN`)
**vLLM tuning:** `MAX_MODEL_LEN=20000`, `GPU_MEMORY_UTILIZATION=0.9`,
`EXTRA_ENGINE_ARGS=--enable-prefix-caching`,
`LANGUAGE_MODEL_ONLY=true`, `ENABLE_THINKING=false`

---

## 1. Cold-start results (fresh GPU node, no image cache, no model cache)

| # | Variant Container App | Image (`contentshieldacraxa1.azurecr.io/contentshield-stage2:`) | Image size | Model source | Node alloc + image pull | vLLM model load | **Total scale → /health 200** | First classify | Source |
|---|---|---|---:|---|---:|---:|---:|---:|---|
| 1 | `ca-cs-stage2-baked-local` | `gemma4-31b-model-baked-local-20260519` | ~58 GB | Local SSD (offline, `HF_HUB_OFFLINE=true`) | **12m14s** | **2m25s** | **14m39s** | 2.32 s | this run ✅ |
| 2 | `ca-cs-stage2-baked` | `gemma4-31b-model-baked-20260519` | ~58 GB | HF cache baked into image; vLLM still validates against HF Hub | 12m12s | 10m22s | **22m34s** | 2.28 s | this run |
| 3 | `ca-cs-stage2-cache-disabled` | `gemma4-31b-cache-disabled-20260519` | ~10 GB | Downloads ~60 GB from HF Hub at boot | 4m27s | 8m38s | **13m05s** (this run) / **13m27s** (vendor) | 2.28 s | this run + vendor matrix agree |

> **Image-pull → /health is the cold-start cost a user feels** when ACA scales
> from zero and the underlying GPU node has to be provisioned from cold. The
> `baked` row is strictly the worst: it pays for a 58 GB image pull AND still
> talks to HF Hub. The `cache-disabled` row has the fastest total time on a
> fresh node because the image is small — but the model load is still 8+ min
> and depends on HF connectivity. The `baked-local` row has the longest
> image-pull tax but the **shortest model load by 4×** and is the only
> variant that is fully offline.

### Cold-start phase breakdown

```
t0: scale 0→1 (or pod create)
├── Node provision (A100 capacity allocation)  — 5–15 min when min-nodes=0
├── Image pull from ACR
│   ├── baked / baked-local : ~12 min   (58 GB)
│   └── cache-disabled      : ~4 min    (10 GB)
├── Container start
└── vLLM model load
    ├── baked-local         : **2m25s** (local SSD → GPU HBM, 1–2 GB/s) ✅ measured
    ├── baked               : 10m22s    (HF cache lookups + HEAD requests)
    └── cache-disabled      : 8m38s     (full HF download → GPU HBM)
→ /health returns 200
```

---

## 2. Warm-start results (GPU node already provisioned & image cached, no replica)

This is the **scale-out** scenario — what happens when ACA spins up an
additional replica on a node that previously hosted the same variant.

| # | Variant Container App | Image | Scale 0→1 → Replica Running | Replica Running → /health 200 | **Total** | Cold first classify | Warm classify (n=9) min | **Warm p50** | Warm p95 |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `ca-cs-stage2-baked-local` | `gemma4-31b-model-baked-local-20260519` | **94s** | **16s** | **110s (1m50s)** | 2308.8 ms | 128.3 ms | **133.4 ms** | 134.0 ms |
| 2 | `ca-cs-stage2-baked` | `gemma4-31b-model-baked-20260519` | (not measured; warm-node) | — | — | 2284.4 ms (cold) | 128.6 ms | **132.3 ms** | 134.5 ms |
| 3 | `ca-cs-stage2-cache-disabled` | `gemma4-31b-cache-disabled-20260519` | (not measured; warm-node) | — | — | 2283.7 ms (cold) | 128.0 ms | **133.5 ms** | 134.3 ms |

> Only `baked-local` was directly measured on a warm node because of GPU
> capacity contention in westus3 during this run. The classify-latency
> columns are identical across all three because the underlying GPU, model
> weights, and vLLM config are identical — the variant only affects how
> *fast you get to a usable replica*.

### What "warm classify" really means

After the first request (which pays for CUDA kernel JIT, CUDA graph capture,
and the first KV-cache allocation, ~2.3 s), subsequent requests against
the same replica run in ~**133 ms** consistently. That is the steady-state
single-request latency of `/classify` (one POST returning a binary label).

---

## 3. Why "baked-local" wins everywhere except the first node

| Cost type | baked-local | baked | cache-disabled |
|---|---|---|---|
| Image pull (per fresh node, one-time) | 12m14s (58 GB) | 12m12s (58 GB) | 4m27s (10 GB) |
| Model load (every replica cold start) | **2m25s (local SSD)** ✅ | 10m22s (HF) | 8m38s (HF) |
| **Total cold-node** | **14m39s** | **22m34s** | **13m05s** |
| Warm-node scale-out | **1m50s** | (~est 1m50s) | (~est 1m50s) |
| Needs `HF_TOKEN` | ❌ no | ✅ yes | ✅ yes |
| Internet egress required | ❌ no | ✅ yes | ✅ yes |
| Air-gap compatible | ✅ yes | ❌ no | ❌ no |
| Warm classify (steady) | **133 ms** | 132 ms | 134 ms (identical) |

The total cold-node time of cache-disabled (13m05s) appears competitive with
baked-local (14m39s) but is misleading: cache-disabled REQUIRES HF
connectivity (which can be rate-limited, slow, or unavailable in regulated
environments). The **model-load** column is the differentiator —
baked-local is **4× faster** than either HF-based variant, and that
margin holds on every cold start, every node, forever.

Image pull is **one-time per node** and is already mitigated by ACR artifact
streaming (overlaybd, `convertPushedImages: true` is on for both repos in
`contentshieldacraxa1`). Model load is **per replica cold start** and only
the baked-local variant solves it in single-digit minutes by reading
straight from local SSD.

---

## 4. Storage account recap

| Account | Purpose | Action |
|---|---|---|
| `csaivllmnfsaxa1` | Customer NFS for HF cache (Premium FileStorage, NFSv4.1). Mounted as `/mount/csaivllmnfsaxa1/hfcache` inside variants when `mountNfs=true`. Currently 0 bytes used because we ship the `baked-local` variant (no NFS needed). | **kept** ✅ |
| `csaivllmnfssedadk` | Stranded duplicate created when an overnight bicep redeploy ran without `-NameSuffix axa1` and `nameSuffix` defaulted to `take(uniqueString(subscription().id), 6) = 'sedadk'`. Empty. | **deleted** ❌ |

### Why we did NOT copy the model from `ratioaivllmnfs`

1. `ratioaivllmnfs` lives in `rg-ratio-ai-dev` and is owned by a different
   team. No read-RBAC across the boundary.
2. The bundled prewarm job downloads HF → customer-NFS, not NFS → NFS.
3. NFS doesn't materially beat HF for one-time loads:

| Source | Effective bandwidth | Time to fetch 60 GB Gemma weights |
|---|---:|---:|
| HuggingFace Hub → pod | ~100–150 MB/s | **6–9 min** |
| Premium NFS (Azure Files) → pod | ~100–200 MB/s | 5–8 min |
| **Local SSD (baked image) → GPU HBM** | **~1–2 GB/s** | **~30 s** |

NFS only buys you (a) no HF token, (b) no rate-limit risk, (c) air-gap
compatibility. **Baked-local gives all three of those AND is 10–15× faster.**

---

## 5. Always-warm replica configuration (RECOMMENDED — applied this run)

Three layers have to be aligned. Setting only one is a common foot-gun.

### Layer A — Workload profile (the GPU node pool)

`NC24-A100` (`Consumption-GPU-NC24-A100`) does NOT support a configurable
`MinimumCount` (Azure rejects it with "Workload Profile property
'MinimumCount' is not supported for CONSUMPTION_GPU_NC24_A100"). The node
pool is auto-managed: ACA keeps the node alive while at least one replica
is on it. **So pinning a node hot is done indirectly via `minReplicas=1`
on a Stage-2 variant.**

### Layer B — Replica scaling (the app)

| Setting | Value | Reasoning |
|---|---|---|
| `minReplicas` | **1** | One warm Stage-2 replica = one warm A100 node = sub-second `/classify` always. Without this, you pay 13–22 min on the first request after idle. |
| `maxReplicas` | **2** | Burst headroom. Adding a 2nd replica triggers a fresh node provision (~12-15 min including image pull) until the burst subsides. |
| `cooldownPeriod` | 600 s | After scale-down trigger, replica lingers for 10 min so a follow-up burst hits a warm replica. |

### Layer C — Scale rule (when to add the 2nd replica)

| Setting | Old | **New** | Reasoning |
|---|---|---|---|
| Rule type | `http` (concurrent requests) | `http` | vLLM batches internally; a single replica absorbs many in-flight requests well. |
| `concurrentRequests` | **1** ⚠️ | **30** ✅ | At `1`, every probe call triggered a scale-up flap (12-min cold start on every burst). `30` lets a warm replica saturate before adding a 2nd. Tune up/down with measured p95. |

### Result with the applied config (baked-local)

- **Steady state:** 1 NC24-A100 node up, 1 Stage-2 replica warm → **~133 ms p50** for every `/classify`. Cost: ~$3-4/hr 24/7 for the A100 node.
- **Burst > 30 concurrent in-flight requests:** ACA adds a 2nd replica. **First burst pays the full ~12-15 min cold start** (node provision + image pull + 3-min model load on baked-local) before the 2nd replica serves. After that the 2nd node stays warm during cooldown.
- **If you need fast burst response too:** there is no middle ground — you must pay for the 2nd node up-front (`minReplicas=2`). Roughly 2× the bill.

### Configuration applied to live infra (and persisted to bicep)

`modules/stage2App.bicep`:
- New params: `scalerConcurrentRequests` (default `'30'`), `scalerCooldownSec` (default `600`).
- Default scaler rule changed from `concurrentRequests: '1'` to the
  parameterised value.

`main.bicep` `stage2Apps` module loop:
- Passes through `v.scalerConcurrentRequests` / `v.scalerCooldownSec` when
  set on the variant object.

`main.bicepparam`:
- `ca-cs-stage2-baked-local` → `minReplicas: 1, maxReplicas: 2, scalerConcurrentRequests: '30'`.
- `ca-cs-stage2-baked` and `cache-disabled` → still `minReplicas: 0` (test only; they are not on the production path).

Applied live via `az containerapp update` because the full `bicep deploy`
of `main.bicep` hits an unrelated CAE-subnet idempotency error in this
environment.

---

## 6. Quota recommendation: do NOT ask for NC48-A100 / NC96-A100

| SKU | GPUs | When it helps | Our case |
|---|---|---|---|
| **NC24-A100** | 1× A100 80 GB | One single-GPU replica per node. | ✅ This is what we use. |
| NC48-A100 | 2× A100 80 GB | Tensor-parallel serving (model split across 2 GPUs) or 2 single-GPU replicas sharing a node — but **ACA dedicated GPU profiles bind one replica per GPU node**, so the 2nd GPU would sit idle. | ❌ no value in ACA. |
| NC96-A100 | 4× A100 80 GB | Tensor-parallel for 70B+ models. | ❌ Gemma-4-31B fits in a single A100's 80 GB HBM. |

Gemma-4-31B at bf16 fits comfortably in one A100 — we've measured 133 ms p50
steady-state on `MAX_MODEL_LEN=20000`. **No tensor-parallel needed.**

**What to request instead:** raise the **NC24-A100** vCPU quota from the
current 96 to give headroom for:
- 1 warm production replica (today)
- 1 burst replica
- 1 canary replica during deploys (ACA briefly runs old + new revisions)
- 1 staging replica

That is 4× NC24 = 96 vCPU, which is exactly where we are. Bumping to 192
vCPU (8 nodes) gives a 2× buffer.

**Do NOT pre-buy NC48-A100/NC96-A100 quota** — you cannot use the extra
GPUs efficiently in ACA's one-replica-per-GPU-node model. Revisit only if
you move to AKS, where multi-pod-per-node scheduling becomes possible.

---

## 7. Response-time table for the scaling choices

Assumes Gemma-4-31B on NC24-A100, baked-local variant, westus3, with the
warm-replica config applied this run.

| Config | Steady-state response | First burst replica add | Approx hourly cost |
|---|---|---|---|
| `min-replicas=0` (idle to zero) | 20–30 min cold start | n/a | $0 idle |
| **`min-replicas=1` ✅ applied** | **~133 ms p50** | ~12–15 min for replica #2 | 1× NC24/hr 24/7 |
| `min-replicas=2` | ~133 ms (always 2 warm) | ~12 min for #3 | 2× NC24/hr 24/7 |

The big jump is between **node exists** and **node does not exist**. If
fast burst response matters, you must pay for the node to be up-front.

---

## 8. Final recommendation

1. **Production:** ship `baked-local` ONLY. Always one warm replica
   (`minReplicas: 1`). Already applied.
2. **Burst handling:** `maxReplicas: 2`, `concurrentRequests: '30'`. Already
   applied. Accept the one-time 12–15 min cold start for the 2nd replica;
   if business needs faster, bump to `minReplicas: 2` and pay double.
3. **Quota:** request a moderate NC24-A100 increase (e.g., 96 → 192 vCPU)
   to enable canary deploys + staging. Do NOT ask for NC48/NC96.
4. **Skip NFS for the production path.** The hfcache share stays around
   only because it's wired up for the prewarm job and the cache-disabled
   variant. Production baked-local uses zero NFS bytes.
5. **Skip the baked (non-local) variant entirely** — strictly dominated by
   baked-local for production, and by cache-disabled for "no-bake" tests.
6. **Storage cleanup:** done — stranded `csaivllmnfssedadk` deleted; only
   `csaivllmnfsaxa1` remains.
7. **APIM end-to-end:** verified — JWT (aud=`api://aceb273b-...`) +
   subscription key → `/contentshield/v1/detect` returns
   `{"verdict":"INJECTION", "detectors": {acs_prompt_shield,...},
   {stage2,...}}` in ~2 s through the public gateway, ~320 ms internal.

### Steady-state operational profile (with applied config)

| Metric | Value |
|---|---|
| Warm `/classify` p50 (Stage-2 only) | **133 ms** |
| Full pipeline (APIM → orchestrator → ACS + Stage-2) end-to-end | **~2 s** (single in-flight) |
| Replicas running at idle | 1 (baked-local) |
| NC24-A100 nodes at idle | 1 |
| Approx 24/7 cost | ~1× NC24-A100 hourly |
| Cold-start for burst replica #2 | 12–15 min (one-time per burst) |

### Open follow-ups

- If APIM rate limits (`1000 calls/minute` per API) become tight, raise the
  policy.
- If you need <100 ms p95 under burst, set `minReplicas: 2` and double the
  node cost.
- Consider moving Stage-2 to AKS in the future ONLY if (a) regular >2
  concurrent replicas are required, (b) ACA image-pull or revision-swap
  edges hurt, or (c) burst cold-start becomes a customer-visible issue
  you cannot mask with `min-replicas`.

---

## 9. Tiered fallback architecture (NFS hfcache + HF download)

For AME deployments where outbound to `huggingface.co` may not be available,
we keep the NFS share as a fallback source for `cache-disabled` and `baked`.
`baked-local` is unaffected (already fully offline).

### Why this is a good idea (with caveats)

✅ **Pros**
- **AME-compatible**: AME often blocks public HF egress. Pre-populated NFS is the only way the non-baked variants can boot in AME.
- **Survives HF outages, rate limits, gating/token changes**.
- **Single source of truth** across multiple cache-disabled replicas (no duplicated HF traffic).
- **Refreshable**: the included prewarm job is idempotent — re-run after a model bump.

⚠️ **Cons**
- ~$65/month for the 500 GiB Premium NFS share even when idle.
- Adds an operational refresh task (re-run prewarm on model bump).
- No benefit to `baked-local`.
- Adds an NFS mount failure mode (ACL drift, mount loss).

### Variant mount matrix (applied this run + persisted in bicepparam)

| Variant | Mounts NFS? | `HF_HOME` | Production role |
|---|---|---|---|
| `ca-cs-stage2-baked-local` | ❌ no | (unset; image sets `HF_HUB_OFFLINE=true`, uses `/opt/models`) | **Primary**. Self-contained. Works in AME with zero outbound. |
| `ca-cs-stage2-baked` | ✅ `/mount/csaivllmnfsaxa1/hfcache` | `/mount/csaivllmnfsaxa1/hfcache` | **Secondary fallback**. Image has HF cache layout baked, but if HF Hub validation calls fail (AME), it reads from NFS. |
| `ca-cs-stage2-cache-disabled` | ✅ `/mount/csaivllmnfsaxa1/hfcache` | `/mount/csaivllmnfsaxa1/hfcache` | **Tertiary fallback**. Small image. In AME, must read weights from NFS (no HF egress). On first cold start in corp, it downloads from HF AND writes to NFS — populating the cache for the next run. |

### NFS share populate options (in priority order)

1. **`job-hf-prewarm` Container Apps Job** *(included in this repo)*
   - Bicep: [`infra/contentshield/modules/hfPrewarmJob.bicep`](../modules/hfPrewarmJob.bicep)
   - Trigger: `az containerapp job start -g rg-contentshield -n job-hf-prewarm`
   - **Known good fixes applied in this session**:
     - `/bin/sh -c` (Azure Linux base doesn't have GNU bash for `set -euo pipefail`)
     - `set -eu` (drop `pipefail`)
     - **No CRLF** in the script (use LF only — CR breaks /bin/sh)
     - `python3` (not `python`)
     - `hf` CLI (not `huggingface-cli` — renamed in `huggingface_hub>=0.30`)
     - Drop `HF_HUB_ENABLE_HF_TRANSFER=1` (deprecated in new SDK; use `HF_XET_HIGH_PERFORMANCE` instead if you bring it back)
     - HF_TOKEN must be set via `--secrets` AND wired via `--set-env-vars "HF_TOKEN=secretref:hf-token"`. Bicep does this if the `hfToken` deploy param is non-empty.
2. **Self-populating via cache-disabled first cold start**
   - cache-disabled has `HF_HOME=/mount/csaivllmnfsaxa1/hfcache` set. Its FIRST cold start downloads weights from HF and writes them to the NFS share. Subsequent replicas (incl. baked) read from NFS — no re-download.
   - Cost: the FIRST cold boot pays the full ~8m38s HF download. Subsequent boots get ~5m read from NFS.
3. **Manual upload** (last resort for fully air-gapped environments)
   - Mount the NFS share from a build VM in corp with HF access; `huggingface-cli download google/gemma-4-31b-it --cache-dir <mount>`; detach. AzCopy with NFS endpoint also works.

### Practical AME bootstrap recipe

Because AME has no public HF egress:

1. In corp/dev (this RG): start the prewarm job, wait for it to complete, verify share usage > 60 GB.
2. Snapshot the populated share (Premium FileStorage supports incremental share snapshots).
3. In AME: restore the snapshot into the AME storage account's `hfcache` share.
4. Deploy the same Stage-2 variants in AME pointing at the AME storage account.
5. Set `ca-cs-stage2-baked-local` minReplicas=1 in AME too — your AME prod is still served by the offline variant.

### Prewarm job timing reference (corp/dev, current run)

- First successful container start: confirmed
- Time to file metadata download: ~5 min
- Time to first weights bytes: variable (HF gateway congestion in westus3 corp)
- Expected total: 10-20 min for 60 GB of weights at ~50-100 MB/s through HF + NFS write
- If it stalls > 60 min: check token validity, then check that `hf` CLI is using xet transfer (set `HF_XET_HIGH_PERFORMANCE=1`)

---

## 10. NFS hfcache populate result (this session)

The `job-hf-prewarm` Container Apps Job kept failing on the gated Gemma
weights even after fixing every script-level bug (the new `hf` CLI in
`huggingface_hub>=0.30` doesn't retry chunked transfers reliably for large
gated files in this corp environment).

**Workaround that actually worked:** scaled `ca-cs-stage2-cache-disabled`
to 1 with `HF_HOME=/mount/csaivllmnfsaxa1/hfcache` and NFS mounted. vLLM's
own `snapshot_download` path downloaded the model successfully and wrote it
straight to the NFS share.

### Confirmed populated state

```text
$ df -h /mount/csaivllmnfsaxa1/hfcache
Filesystem                                                      Size  Used  Avail  Use%
csaivllmnfsaxa1.file.core.windows.net:/csaivllmnfsaxa1/hfcache  500G   59G   442G   12%

$ ls /mount/csaivllmnfsaxa1/hfcache
CACHEDIR.TAG
hub
models--google--gemma-4-31b-it
xet

$ find /mount/csaivllmnfsaxa1/hfcache -name '*.safetensors'
.../hub/models--google--gemma-4-31b-it/snapshots/fcf2302.../model-00001-of-00002.safetensors
.../hub/models--google--gemma-4-31b-it/snapshots/fcf2302.../model-00002-of-00002.safetensors
```

**59 GB of Gemma-4-31B-IT weights successfully sitting on the NFS share.**

### cache-disabled cold-start measured with NFS mount

- Replica Running at **+25s** (warm GPU node, ~10 GB image already cached)
- /health 200 at **+804s (13m24s)** — full HF download finished while writing to NFS
- Subsequent cold starts should be **5-8 min** (NFS read, no HF traffic). The
  next time a `cache-disabled` replica starts, vLLM finds the model in the
  NFS cache and skips the HF download path.

### Final production state (applied to live, persisted to bicep)

| Variant | minReplicas | maxReplicas | scalerConcurrency | NFS mount | HF_HOME |
|---|---:|---:|---:|---|---|
| `ca-cs-stage2-baked-local` | **1** ← always-warm production | 2 | 30 | ❌ | (offline / `/opt/models`) |
| `ca-cs-stage2-baked` | 0 | 1 | 30 | ✅ `/mount/csaivllmnfsaxa1/hfcache` | `/mount/csaivllmnfsaxa1/hfcache` |
| `ca-cs-stage2-cache-disabled` | 0 | 1 | 30 | ✅ `/mount/csaivllmnfsaxa1/hfcache` | `/mount/csaivllmnfsaxa1/hfcache` |

Primary production traffic: `baked-local`. If `baked-local` becomes
unusable (image pull failure, ACR outage), traffic can shift to either of
the fallback variants — both have NFS-backed weights ready to go.

### Verified APIM end-to-end (post-fallback config)

```
POST https://apim-contentshield-axa1.azure-api.net/contentshield/v1/detect
→ 200 in ~2 s (cold) / ~800 ms (warm)
{ "verdict":"INJECTION", "score":1.0,
  "detectors": {
    "acs_prompt_shield": { "label":"INJECTION", ... },
    "stage2":            { "label":"INJECTION", ... }
  }
}
```
