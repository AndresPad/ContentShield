# ContentShield Current System Design

This document describes the current V1 ContentShield deployment. Historical PoC app names, detector names, and dynamic detector-registry configuration are not part of the current runtime.

## Goals

ContentShield provides a single HTTP detection API for prompt-injection screening before user content reaches downstream AI systems.

V1 goals:

- Keep the public API stable at `POST /v1/detect`.
- Run cheap detectors before expensive GPU inference.
- Let the service degrade gracefully when optional detector dependencies are not configured.
- Keep Stage2 independently deployable and replaceable.
- Make deployment reproducible from source plus configuration.

## Services

ContentShield is deployed as two independently built images.

| Service | Image | Compute | Ingress | Purpose |
|---|---|---|---|---|
| `ca-ratio-contentshield-dev` | `ratioaidev.azurecr.io/contentshield:<tag>` | CPU | External | Public API, detector policy, ACS, Stage1, Stage2 client |
| `ca-contentshield-stage2` | `ratioaidev.azurecr.io/contentshield-stage2:<tag>` | `GPUNC24A100` GPU | External in dev | vLLM + FastAPI wrapper for Gemma 4 Stage2 classification |

The current dev deployment runs both apps in `rg-ratio-ai-dev` and `cae-ratio-vllm-dev` in `westus3`.

## Request Flow

```text
caller
  |
  | POST /v1/detect
  v
ca-ratio-contentshield-dev
  |
  | Layer 1, parallel
  | - acs_prompt_shield
  | - stage1
  | - query_detect when options.enable_query_detection=true
  |
  | if Layer 1 detects injection: return INJECTION and stop
  |
  | Layer 2, sequential
  | - stage2 over HTTP when mode=standard and SLM_ENDPOINT is configured
  v
ca-contentshield-stage2
  |
  | local OpenAI-compatible vLLM server
  v
google/gemma-4-31b-it
```

Deep mode is reserved for a future V2 LLM detector and intentionally returns HTTP 400 in V1.

## Detector Contracts

### ACS Prompt Shield

- Name: `acs_prompt_shield`
- Configuration: `CONTENT_SAFETY_ENDPOINT`, optional `CONTENT_SAFETY_KEY`
- Auth: `DefaultAzureCredential` when no key is supplied
- Output: normalized `DetectorResult`
- Reason contract: normalized evidence derived from the ACS `attackDetected` boolean. The ACS `2024-09-01` Prompt Shield success response does not include a free-text reason.
- Missing config: `skipped`

### Stage1

- Name: `stage1`
- Dependencies: Azure OpenAI embeddings and committed sklearn model artifact
- Configuration: `STAGE1_AOAI_ENDPOINT`, `STAGE1_AOAI_EMBEDDING_DEPLOYMENT`, optional API key
- Auth: `DefaultAzureCredential` when no key is supplied
- Missing AOAI config: `skipped`
- Model artifact: `src/contentshield/infrastructure/stage1/models/stage1_logreg.joblib`
- Integrity: SHA-256 checked against `stage1_logreg.sha256` at import time
- Reason contract: normalized evidence from score, threshold, chunk count, and early-stop state. This reserves the same public field for future model-native reasoning.

### Query Detection

- Name: `query_detect`
- Runs only when request options enable query detection
- Intended as a lightweight Layer 1 signal

### Stage2

- Name: `stage2`
- Configuration: `SLM_ENDPOINT`, `SLM_PATH`, `SLM_TIMEOUT_SECONDS`, `SLM_MODEL`
- Current service contract: `POST /classify` with `{"text":"..."}`
- Response: `{"injection": true|false, "label": "YES"|"NO", "reason": ""}`
- Reason contract: intentionally blank for this release. Stage2 may use private/internal reasoning, but the final public content is verdict-only.
- Missing config: `skipped`
- Raw OpenAI-compatible fallback: if `SLM_PATH` is `/v1/chat/completions`, the client sends a chat completion payload with guided `YES`/`NO` decoding and parses `choices[0].message.content` as `YES` or `NO`; any legacy public reason text is ignored.

## Stage2 Runtime

Stage2 builds from a pinned known-good Stage2 runtime image by default: `ratioaidev.azurecr.io/contentshield-stage2:v1`. The application image overlays the current wrapper source, prompt, and startup script onto that base so the vLLM, CUDA, Torch, NumPy, and Transformers stack stays reproducible. The Dockerfile still accepts `BASE_IMAGE` and `EXTRA_PIP_PACKAGES` build args for controlled validation builds.

Avoid mutable GPU runtime tags such as `latest` for normal Stage2 builds. A base-image drift can change the vLLM dependency stack without a ContentShield code change.

The container starts two processes:

1. Local vLLM OpenAI-compatible API on `127.0.0.1:8000`.
2. FastAPI wrapper on `0.0.0.0:8080` exposing `/health` and `/classify`.

The wrapper health endpoint returns 200 only after vLLM is reachable. During cold start, `/health` can return 503 while Gemma weights load. A mounted Hugging Face cache avoids re-downloading model weights, but vLLM still needs time to page and load the 31B checkpoint into GPU memory.

Reference settings:

```text
MODEL_NAME=google/gemma-4-31b-it
MAX_MODEL_LEN=20000
GPU_MEMORY_UTILIZATION=0.9
LANGUAGE_MODEL_ONLY=true
ENABLE_THINKING=false
EXTRA_ENGINE_ARGS=--enable-prefix-caching
ENABLE_STAGE2_REASON=true
MAX_REASON_TOKENS=256
HF_HOME=/mnt/hfcache
HF_TOKEN=secretref:hf-token
```

The active V1 path does not enable Gemma hidden thinking or the Gemma reasoning parser. Stage2 uses vLLM guided choice decoding for a single visible `YES`/`NO` label. When `ENABLE_STAGE2_REASON=true`, Stage2 makes a second short SLM call only after a `YES` label to populate a one-sentence public `reason` field. `NO` labels return immediately with an empty reason.

Classifier and reason prompts are runtime configuration, not model artifacts. Use `CLASSIFIER_PROMPT_TEXT` and `REASON_PROMPT_TEXT` for feature-container prompt experiments so prompt tuning creates a new Container Apps revision without rebuilding the Stage2 image. The packaged prompt files are fallback defaults for local and baseline deployments.

Gemma 4 31B's native text context window is 262,144 tokens. The current single-A100 dev deployment intentionally serves it with `MAX_MODEL_LEN=20000`, which is the validated stable context window for this service profile. Larger contexts require separate GPU memory, quantization, or parallelism validation.

`HF_TOKEN` is required for gated Hugging Face model access. It must be supplied as an Azure Container Apps secret or equivalent secret manager value.

## Configuration Model

The orchestrator loads configuration from environment variables and a local `.env` file for development. Production injects the same values through Container App environment variables.

The committed handoff template is `config.sample.env`. Real `.env` files are ignored and must not be committed.

`uv.lock` is committed because the orchestrator Dockerfile copies it and runs `uv sync --frozen` during image build. The lock file is baked into the image build output; it is not read at runtime by the deployed app.

## Azure RBAC

When API keys are not supplied, the orchestrator uses `DefaultAzureCredential` to call Cognitive Services. In ACA this resolves to the Container App managed identity.

Required runtime roles:

| Resource | Role |
|---|---|
| Azure AI Content Safety resource | `Cognitive Services User` |
| Azure OpenAI resource | `Cognitive Services OpenAI User` |
| Private ACR used for image pull | `AcrPull` for the configured registry pull identity |

Human user access does not grant runtime access to the Container App identity. Grant roles to the managed identity itself or to a group containing that managed identity.

## Deployment Sequence

1. Build/push Stage2 image.
2. Deploy or update `ca-contentshield-stage2` on GPU profile `GPUNC24A100`.
3. Wait for Stage2 `/health` to return 200.
4. Build/push orchestrator image.
5. Deploy or update `ca-ratio-contentshield-dev` with `SLM_ENDPOINT=https://<stage2-fqdn>` and `SLM_PATH=/classify`.
6. Assign managed identity to orchestrator if missing.
7. Grant Content Safety and Azure OpenAI RBAC.
8. Restart the latest orchestrator revision after RBAC propagation.
9. Run `/health`, safe request, injection request, and forced Stage2 request.

The README contains command-level deployment steps.

## Local Compose

`docker compose up --build app` runs the orchestrator only. This is the normal developer path and expects `.env` to point `SLM_ENDPOINT` at a deployed Stage2 service.

`docker compose --profile gpu up --build` also starts a local Stage2 service. This requires NVIDIA Container Toolkit, a GPU capable of serving the model, and a valid `HF_TOKEN`.

## Operational Notes

- The dev ACA environment has a limited GPU workload profile. Stale active GPU revisions can consume capacity even when traffic is not flowing.
- If Stage2 cannot allocate the workload profile, check active revisions and retired apps before changing code.
- `SLM_PATH=/classify` is required for the FastAPI wrapper. Without it, the client defaults to `/v1/chat/completions` for raw vLLM compatibility.
- Stage2 may be absent in obvious injection responses because Layer 1 early-stop is expected behavior.
- The old PoC classifier app has been retired and should not be used for new deployments.

## Validation

Before handoff, run:

```bash
cd RatioAI.ContentShield
uv run pytest -q
uv run pytest -m e2e -q -rs
uv run ruff check .
az acr build --registry <registry-name> --image contentshield:validation .
az acr build --registry <registry-name> --image contentshield-stage2:validation services/stage2
```
