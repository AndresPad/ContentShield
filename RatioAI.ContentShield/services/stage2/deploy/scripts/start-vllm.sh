#!/usr/bin/env bash
set -euo pipefail

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

if [[ -n "${HF_TOKEN:-}" ]]; then
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
fi

if [[ -n "${HF_HOME:-}" ]]; then
  mkdir -p "$HF_HOME"
fi

ARGS=(
  --model "$MODEL_NAME"
  --host 127.0.0.1
  --port "$VLLM_PORT"
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --dtype "$DTYPE"
)

if [[ "$LANGUAGE_MODEL_ONLY" == "true" ]]; then
  ARGS+=(--language-model-only)
fi

# Append any model-specific flags (e.g., --chat-template-kwargs, --reasoning-parser)
if [[ -n "$EXTRA_ENGINE_ARGS" ]]; then
  read -ra EXTRA <<< "$EXTRA_ENGINE_ARGS"
  ARGS+=("${EXTRA[@]}")
fi

# Server-wide default chat template kwargs (e.g., Gemma 4 enable_thinking)
if [[ -n "$DEFAULT_CHAT_TEMPLATE_KWARGS" ]]; then
  ARGS+=(--default-chat-template-kwargs "$DEFAULT_CHAT_TEMPLATE_KWARGS")
fi

# Start vLLM in the background; forward signals so SIGTERM cleans up the GPU.
python3 -m vllm.entrypoints.openai.api_server "${ARGS[@]}" &
VLLM_PID=$!
trap 'echo "stopping vLLM ($VLLM_PID)"; kill -TERM $VLLM_PID 2>/dev/null || true; wait $VLLM_PID 2>/dev/null || true' SIGINT SIGTERM EXIT

# Foreground: FastAPI wrapper. Wrapper /health probes vLLM until it warms up.
export VLLM_URL="${VLLM_URL:-http://127.0.0.1:${VLLM_PORT}}"
export VLLM_HEALTH_URL="${VLLM_HEALTH_URL:-${VLLM_URL%/}/health}"
export MODEL_NAME
exec uvicorn stage2.main:app --host "$HOST" --port "$WRAPPER_PORT" --log-level info
