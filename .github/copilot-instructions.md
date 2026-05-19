# ContentShield — Copilot Instructions

ContentShield is a prompt-injection detection service for enterprise AI systems. This repo holds the **application code and container images** (Python / FastAPI). Azure infrastructure (Bicep + PowerShell) lives under [../infra/contentshield/](../infra/contentshield/) and is out of scope for most application work — confirm with the user before editing infra.

When a change is requested, first decide whether the user means the **application** (this guide) or the **infra** (see [../infra/contentshield/README.md](../infra/contentshield/README.md)).

## Two container images, one repo

All product code is under [../RatioAI.ContentShield/](../RatioAI.ContentShield/) and builds into **two images**:

| Image | Source | Dockerfile | Role |
|---|---|---|---|
| **Orchestrator** (CPU) | [../RatioAI.ContentShield/src/contentshield/](../RatioAI.ContentShield/src/contentshield/) | [../RatioAI.ContentShield/Dockerfile](../RatioAI.ContentShield/Dockerfile) | FastAPI service owning the public `/v1/detect` API, detector policy, ACS + Stage1 + Stage2 client. Runs as non-root `app` user on port `8080`. |
| **Stage2** (GPU) | [../RatioAI.ContentShield/services/stage2/src/stage2/](../RatioAI.ContentShield/services/stage2/src/stage2/) | [../RatioAI.ContentShield/services/stage2/Dockerfile](../RatioAI.ContentShield/services/stage2/Dockerfile) | Thin FastAPI wrapper over an in-container vLLM serving `google/gemma-4-31b-it`. Exposes `/health` and `/classify`. |

The Stage2 Dockerfile is a **derived image** layered on a pre-built vLLM base (`ARG BASE_IMAGE=ratioaidev.azurecr.io/contentshield-stage2:v1`). It only adds the wrapper code, prompts, and `start-vllm.sh`. Do not introduce a from-scratch CUDA/vLLM build here without explicit user approval — it changes the publish flow.

Both images are pulled by Azure Container Apps using the environment's system-assigned managed identity (`registries: { identity: 'system-environment' }`). **Never embed registry credentials in code or images.**

## Orchestrator architecture

Read in this order to understand the wiring (mirrors the comment block at the top of [../RatioAI.ContentShield/src/contentshield/app.py](../RatioAI.ContentShield/src/contentshield/app.py)):

```
app.py                              # composition root, lifespan, create_app()
api/routes.py + models.py + mappers.py   # HTTP transport, Pydantic DTOs, DTO↔domain
orchestrator/pipeline.py            # detector policy, timeouts, verdict rule
domain/models.py + errors.py        # pure domain types — no I/O, no FastAPI
infrastructure/                     # adapters (one file per detector)
  acs_prompt_shield.py
  stage1/{detector,classifier,embedder,chunker}.py
  query_detect.py
  stage2_client.py
  detectors.py                      # build_default_detectors() — wiring lives here
```

**Layering rule:** `domain/` is pure (no httpx, no FastAPI, no env reads). `infrastructure/` may import `domain/`. `orchestrator/` orchestrates infrastructure. `api/` is the only layer that touches FastAPI types. Do not introduce reverse imports.

### Detector pipeline rules

- All wired detectors run in **parallel** with per-detector timeout budgets in `TIMEOUTS` (pipeline.py). Each detector is wrapped by `_run_detector` which **never raises** — it returns `DetectorResult.timed_out()` or `.failed()`.
- **Stage2 is the authoritative verdict** in V1: when Stage2 completes, its `detected` value is the final verdict regardless of other detectors. ACS runs alongside as advisory signal only.
- If every attempted detector ends in `FAILED`/`TIMED_OUT`, the pipeline **fails closed** and forces `Verdict.INJECTION`. Preserve this — do not "improve" by defaulting to benign.
- V1 wiring (`CONTENTSHIELD_V1_ML_DISABLED=1`, the default) wires only `acs_prompt_shield + stage2`. `stage1` and `query_detect` exist in the code but are unwired. Set the env var to `0` to enable the full set (V2 / local experiments). No code change should be required to flip this.
- `mode=fast` and `mode=deep` are intentionally `400` in V1. `mode=standard` is the only supported value. Keep these stubs unless the user asks to implement them.
- Diagnostic override `"detectors": [...]` runs only the named detectors and switches verdict to OR semantics over completed requested detectors. Requesting an unwired detector returns `failed` for that detector and triggers fail-closed.
- Missing detector config (blank endpoint env vars) must produce `skipped` detector results at runtime — not a boot-time failure.

## Stage2 service rules

- The Stage2 wrapper ([../RatioAI.ContentShield/services/stage2/src/stage2/main.py](../RatioAI.ContentShield/services/stage2/src/stage2/main.py)) talks to vLLM over the OpenAI-compatible API at `VLLM_URL` (default `http://localhost:8000`, same container).
- `/classify` returns a **binary label** via vLLM guided-choice decoding and an intentionally blank `reason` field. Only when `ENABLE_STAGE2_REASON=true` does a `YES` label trigger a second short SLM call (capped by `MAX_REASON_TOKENS`, default 64) to populate `reason`. `NO` returns immediately with empty reason. Preserve this gating — it controls cost and latency.
- Prompts are loaded at startup from `PROMPT_PATH` / `REASON_PROMPT_PATH`, with `CLASSIFIER_PROMPT_TEXT` / `REASON_PROMPT_TEXT` as inline overrides. **Prefer the inline-text env vars for prompt experiments** so a feature container can ship a new prompt without rebuilding the Stage2 image.
- The active V1 path is **label-only guided decoding**. Do not enable the Gemma reasoning parser or `ENABLE_THINKING=true` for V1 without explicit ask — they break the contract.
- `MAX_MODEL_LEN=20000` is the validated single-A100 context window; `GPU_MEMORY_UTILIZATION=0.9` and `EXTRA_ENGINE_ARGS=--enable-prefix-caching` are the validated defaults. Don't change these without a test pass.

## Config and secrets

- All endpoints, models, thresholds, and toggles are read from **environment variables at startup**. Swapping a model or endpoint must remain a config-only change (Container Apps env var update → new revision). Do not hard-code endpoints, model names, or thresholds.
- [../RatioAI.ContentShield/config.sample.env](../RatioAI.ContentShield/config.sample.env) is the canonical handoff template. When you add a new env var, also add it to this file (with a placeholder, never a real secret) and to the env table in [../RatioAI.ContentShield/README.md](../RatioAI.ContentShield/README.md).
- Azure authentication uses `DefaultAzureCredential` when the corresponding `*_KEY` env var is blank. `auth.warm_credential()` runs in the FastAPI lifespan so the first detector call is hot — keep that warm-up call when adding new managed-identity adapters.
- Secrets (`HF_TOKEN`, `*_KEY`) must never be committed. In Azure they flow through Container Apps secrets (`secretref:hf-token`). `.env` is git-ignored.

## Local development

Always work from the `RatioAI.ContentShield/` subfolder for app commands:

```powershell
cd RatioAI.ContentShield
uv sync                                              # install deps incl. dev group
uv run pytest -q                                     # default test run (excludes e2e + legacy_pipeline)
uv run ruff check .                                  # lint
uv run uvicorn contentshield.app:app --port 8000     # run orchestrator
```

For cloud-backed checks: `az login --tenant <id>`, copy `config.sample.env` → `.env`, fill real endpoints, then `uv run pytest -m e2e -q -rs` or `uv run python Scripts/dac_smoke.py`.

Docker compose has two profiles:

```powershell
# Default: orchestrator only, points at a deployed Stage2 via SLM_ENDPOINT
docker compose up --build app

# GPU host with NVIDIA Container Toolkit, runs Stage2 locally too
docker compose --profile gpu up --build
```

## Test conventions

- Pytest markers (registered in [../RatioAI.ContentShield/pyproject.toml](../RatioAI.ContentShield/pyproject.toml)):
  - `integration` — needs live external services.
  - `e2e` — needs Azure login + real cloud config. `tests/e2e/conftest.py` handles env loading.
  - `legacy_pipeline` — Stage1 / query_detect tests; excluded from the default V1 run.
- Default `addopts = -m "not e2e and not legacy_pipeline"`. New unit tests must be runnable under this default (no network, no GPU).
- Unit tests pass fakes via `create_app(detectors=...)`. Do not patch module globals when dependency injection is available.
- New detectors need: a unit test against a fake transport, a wiring test in `tests/test_pipeline.py` style, and a timeout entry in `TIMEOUTS`.

## Lint / style

- Ruff config: [../RatioAI.ContentShield/ruff.toml](../RatioAI.ContentShield/ruff.toml). Google docstring convention, line length 100, target py311. `D100/D104/D105/D107` ignored.
- `evals/` is excluded from lint (research code). `tests/*` skip docstring rules.
- Public functions and classes need Google-style docstrings. Test methods do not.

## Stage1 ML model

- `src/contentshield/infrastructure/stage1/models/` holds a pre-trained logistic-regression joblib. **`scikit-learn` is pinned `>=1.7.2,<1.8`** in `pyproject.toml` because the artifact was pickled on 1.7.x. Lift the cap only when the model is retrained and re-pickled on the new version — and update the comment in `pyproject.toml`.

## When in doubt

- Application change → this repo, this guide.
- Container App revision rules, image pull identity, GPU profile, NFS mount, networking → [../infra/contentshield/](../infra/contentshield/) and its README/copilot rules.
- Product behavior outside what's wired here → [../RatioAI.ContentShield/docs/SYSTEM_DESIGN.md](../RatioAI.ContentShield/docs/SYSTEM_DESIGN.md). It describes the target design; some pieces (e.g. `mode=fast`, `mode=deep`, Stage1 in production) are deliberately not in V1.
