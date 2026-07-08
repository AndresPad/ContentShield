#!/bin/sh
set -eu

MODEL_NAME="${MODEL_NAME:-google/gemma-4-31b-it}"
HOST="${HOST:-0.0.0.0}"
VLLM_PORT="${VLLM_PORT:-8000}"
WRAPPER_PORT="${WRAPPER_PORT:-8080}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-1}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-20000}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.9}"
DTYPE="${DTYPE:-auto}"
EXTRA_ENGINE_ARGS="${EXTRA_ENGINE_ARGS:-}"
DEFAULT_CHAT_TEMPLATE_KWARGS="${DEFAULT_CHAT_TEMPLATE_KWARGS:-}"
LANGUAGE_MODEL_ONLY="${LANGUAGE_MODEL_ONLY:-false}"
ALLOW_ENFORCE_EAGER="${ALLOW_ENFORCE_EAGER:-false}"
STAGE2_PREFLIGHT_MODEL_CHECK="${STAGE2_PREFLIGHT_MODEL_CHECK:-true}"
VLLM_REQUIRE_READY_BEFORE_WRAPPER="${VLLM_REQUIRE_READY_BEFORE_WRAPPER:-true}"
VLLM_STARTUP_TIMEOUT_S="${VLLM_STARTUP_TIMEOUT_S:-900}"
VLLM_STARTUP_POLL_S="${VLLM_STARTUP_POLL_S:-2}"
STAGE2_PREFER_BAKED_MODEL="${STAGE2_PREFER_BAKED_MODEL:-true}"
BAKED_MODEL_PATH="${BAKED_MODEL_PATH:-/opt/models/gemma-4-31b-it}"

if [ -n "${HF_TOKEN:-}" ]; then
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
fi

if [ -n "${HF_HOME:-}" ]; then
  mkdir -p "$HF_HOME"
fi

# Self-heal MODEL_NAME for baked-local images. The baked-local image ships the
# weights on local disk at BAKED_MODEL_PATH and runs with HF_HUB_OFFLINE=true.
# If the deployment overrides MODEL_NAME with a Hugging Face repo id (e.g.
# "google/gemma-4-31b-it") instead of the baked local path, vLLM would attempt an
# online snapshot_download that fails closed under offline mode. When the
# provided MODEL_NAME is not a local directory but the baked weights are present,
# fall back to them so the container serves regardless of the injected value.
if [ "$STAGE2_PREFER_BAKED_MODEL" = "true" ] \
  && [ ! -d "$MODEL_NAME" ] \
  && [ -f "$BAKED_MODEL_PATH/config.json" ]; then
  echo "MODEL_NAME='$MODEL_NAME' is not a local directory; using baked weights at '$BAKED_MODEL_PATH'"
  MODEL_NAME="$BAKED_MODEL_PATH"
fi

if [ "$STAGE2_PREFLIGHT_MODEL_CHECK" = "true" ] && [ ! -d "$MODEL_NAME" ]; then
  echo "Running Stage2 model preflight for $MODEL_NAME"
  python3 - "$MODEL_NAME" <<'PY'
import os
import sys

from huggingface_hub import snapshot_download


model_name = sys.argv[1]
offline = os.getenv("HF_HUB_OFFLINE", "").strip().lower() in {"1", "true", "yes", "on"}
local_files_only = offline

try:
    snapshot_download(
        repo_id=model_name,
        allow_patterns=["config.json"],
        local_files_only=local_files_only,
    )
except Exception as exc:
    mode = "offline" if offline else "online"
    raise SystemExit(
        "Stage2 model preflight failed for "
        f"{model_name!r} in {mode} mode. "
        "Ensure the model is pre-cached in HF_HOME/HUGGINGFACE_HUB_CACHE "
        "or allow outbound Hugging Face access during cold start. "
        f"Root error: {exc}"
    )
PY
fi

set -- \
  --model "$MODEL_NAME" \
  --host 127.0.0.1 \
  --port "$VLLM_PORT" \
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE" \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --dtype "$DTYPE"

if [ "$LANGUAGE_MODEL_ONLY" = "true" ]; then
  set -- "$@" --language-model-only
fi

# Append any model-specific flags (e.g., --chat-template-kwargs, --reasoning-parser)
if [ -n "$EXTRA_ENGINE_ARGS" ]; then
  # Intentionally split EXTRA_ENGINE_ARGS into separate CLI flags.
  # shellcheck disable=SC2086
  for arg in $EXTRA_ENGINE_ARGS; do
    if [ "$arg" = "--enforce-eager" ] && [ "$ALLOW_ENFORCE_EAGER" != "true" ]; then
      echo "Ignoring --enforce-eager so vLLM can use torch.compile/CUDA graphs"
      continue
    fi
    set -- "$@" "$arg"
  done
fi

# Server-wide default chat template kwargs (e.g., Gemma 4 enable_thinking)
if [ -n "$DEFAULT_CHAT_TEMPLATE_KWARGS" ]; then
  set -- "$@" --default-chat-template-kwargs "$DEFAULT_CHAT_TEMPLATE_KWARGS"
fi

# Start vLLM in the background; forward signals so SIGTERM cleans up the GPU.
python3 -m vllm.entrypoints.openai.api_server "$@" &
VLLM_PID=$!
trap 'echo "stopping vLLM ($VLLM_PID)"; kill -TERM "$VLLM_PID" 2>/dev/null || true; wait "$VLLM_PID" 2>/dev/null || true' INT TERM EXIT

# Foreground: FastAPI wrapper. Wrapper /health probes vLLM until it warms up.
export VLLM_URL="${VLLM_URL:-http://127.0.0.1:${VLLM_PORT}}"
export VLLM_HEALTH_URL="${VLLM_HEALTH_URL:-${VLLM_URL%/}/health}"

if [ "$VLLM_REQUIRE_READY_BEFORE_WRAPPER" = "true" ]; then
  echo "Waiting for vLLM readiness at $VLLM_HEALTH_URL"
  START_TS="$(date +%s)"
  while true; do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
      echo "vLLM exited before becoming ready"
      wait "$VLLM_PID"
      exit 1
    fi

    if python3 - "$VLLM_HEALTH_URL" <<'PY'
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=2) as resp:
        raise SystemExit(0 if resp.status == 200 else 1)
except (urllib.error.URLError, TimeoutError):
    raise SystemExit(1)
PY
    then
      echo "vLLM is ready"
      break
    fi

    NOW_TS="$(date +%s)"
    if [ $((NOW_TS - START_TS)) -ge "$VLLM_STARTUP_TIMEOUT_S" ]; then
      echo "Timed out waiting for vLLM readiness after ${VLLM_STARTUP_TIMEOUT_S}s"
      kill -TERM "$VLLM_PID" 2>/dev/null || true
      wait "$VLLM_PID" 2>/dev/null || true
      exit 1
    fi

    sleep "$VLLM_STARTUP_POLL_S"
  done
fi

export MODEL_NAME
exec uvicorn stage2.main:app --host "$HOST" --port "$WRAPPER_PORT" --log-level info
