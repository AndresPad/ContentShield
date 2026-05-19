"""ContentShield Stage-2 classifier wrapper.

Thin FastAPI service that fronts a local vLLM OpenAI-compatible server.
Loads the v6 prompt at startup, exposes a clean POST /classify contract.
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

VLLM_URL = os.environ.get("VLLM_URL", "http://localhost:8000")
PROMPT_PATH = os.environ.get(
    "PROMPT_PATH", "/workspace/prompts/pi-classifier-v6.txt"
)
CLASSIFIER_PROMPT_TEXT = os.environ.get("CLASSIFIER_PROMPT_TEXT")
MODEL_NAME = os.environ.get("MODEL_NAME", "google/gemma-4-31b-it")
VLLM_TIMEOUT_S = float(os.environ.get("VLLM_TIMEOUT_S", "30"))
REASON_PROMPT_PATH = os.environ.get(
    "REASON_PROMPT_PATH", "/workspace/prompts/pi-reason-v1.txt"
)
REASON_PROMPT_TEXT = os.environ.get("REASON_PROMPT_TEXT")
ENABLE_STAGE2_REASON = os.environ.get("ENABLE_STAGE2_REASON", "false").strip().lower() in {
    "1",
    "true",
    "yes",
}
_MAX_REASON_TOKENS_RAW = os.environ.get("MAX_REASON_TOKENS", "64")
MAX_REASON_TOKENS = 64
if ENABLE_STAGE2_REASON:
    try:
        MAX_REASON_TOKENS = int(_MAX_REASON_TOKENS_RAW)
    except ValueError as exc:
        raise RuntimeError(
            f"Invalid MAX_REASON_TOKENS={_MAX_REASON_TOKENS_RAW!r}; must be an integer"
        ) from exc
_MAX_CLASSIFY_TOKENS_RAW = os.environ.get("MAX_CLASSIFY_TOKENS", "512")
try:
    MAX_CLASSIFY_TOKENS = int(_MAX_CLASSIFY_TOKENS_RAW)
except ValueError as exc:
    raise RuntimeError(
        f"Invalid MAX_CLASSIFY_TOKENS={_MAX_CLASSIFY_TOKENS_RAW!r}; must be an integer"
    ) from exc


class ClassifyRequest(BaseModel):
    """Request body for Stage-2 prompt-injection classification."""

    text: str = Field(..., min_length=1)


class ClassifyResponse(BaseModel):
    """Binary Stage-2 classification result."""

    injection: bool
    label: str  # "YES" | "NO"
    reason: str = Field(default="", max_length=200)


_state: dict[str, object] = {}


def _completion_extra_body() -> dict[str, object]:
    return {"guided_choice": ["YES", "NO"]}


def _parse_label(content: str) -> str | None:
    first_token = content.strip().split(None, 1)[0] if content.strip() else ""
    normalized = first_token.strip(" \t\r\n.,;:!?\"'`()[]{}").upper()
    return normalized if normalized in {"YES", "NO"} else None


def _clean_reason(content: str) -> str:
    reason = " ".join(content.strip().split())
    if len(reason) <= 200:
        return reason

    sentence_end = max(reason.rfind(mark, 0, 200) for mark in ".!?")
    if sentence_end >= 80:
        return reason[: sentence_end + 1].rstrip()[:200]

    shortened = reason[:197].rsplit(" ", 1)[0].rstrip(" ,;:")
    return f"{shortened}..." if shortened else ""


def _load_prompt(*, prompt_text: str | None, prompt_path: str, name: str) -> str:
    if prompt_text and prompt_text.strip():
        return prompt_text.strip()

    with open(prompt_path, encoding="utf-8") as f:
        prompt = f.read().strip()
    if not prompt:
        raise RuntimeError(f"{name} prompt is empty: {prompt_path}")
    return prompt


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the system prompt once and prepare the vLLM client."""
    _state["system_prompt"] = _load_prompt(
        prompt_text=CLASSIFIER_PROMPT_TEXT,
        prompt_path=PROMPT_PATH,
        name="Classifier",
    )
    if ENABLE_STAGE2_REASON:
        _state["reason_prompt"] = _load_prompt(
            prompt_text=REASON_PROMPT_TEXT,
            prompt_path=REASON_PROMPT_PATH,
            name="Reason",
        )
    _state["client"] = AsyncOpenAI(
        base_url=f"{VLLM_URL}/v1",
        api_key="EMPTY",  # vLLM ignores the key by default
        timeout=VLLM_TIMEOUT_S,
    )
    system_prompt: str = _state["system_prompt"]  # type: ignore[assignment]
    logger.info("Stage2 wrapper ready: prompt=%d chars", len(system_prompt))
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    """200 only when both wrapper is up and vLLM is reachable."""
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(f"{VLLM_URL}/health")
        if r.status_code != 200:
            raise HTTPException(503, detail="vllm_unhealthy")
    except httpx.RequestError as exc:
        raise HTTPException(503, detail="vllm_unreachable") from exc
    return {"status": "ok", "service": "stage2"}


@app.post("/classify", response_model=ClassifyResponse)
async def classify(req: ClassifyRequest) -> ClassifyResponse:
    """Classify user text as prompt injection or safe content."""
    client: AsyncOpenAI = _state["client"]  # type: ignore[assignment]
    system_prompt: str = _state["system_prompt"]  # type: ignore[assignment]

    try:
        resp = await client.chat.completions.create(
            model=MODEL_NAME,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": req.text},
            ],
            temperature=0.0,
            max_tokens=MAX_CLASSIFY_TOKENS,
            extra_body=_completion_extra_body(),
        )
    except Exception as exc:
        logger.exception("vLLM call failed")
        raise HTTPException(502, detail="vllm_call_failed") from exc

    content = resp.choices[0].message.content or ""
    label = _parse_label(content)
    if label == "YES":
        reason = await _generate_reason(req.text, client)
        return ClassifyResponse(injection=True, label="YES", reason=reason)
    if label == "NO":
        return ClassifyResponse(injection=False, label="NO", reason="")

    logger.error("Stage2 invalid response: %r", content)
    raise HTTPException(502, detail="invalid_response")


async def _generate_reason(text: str, client: AsyncOpenAI) -> str:
    if not ENABLE_STAGE2_REASON:
        return ""

    reason_prompt: str = _state["reason_prompt"]  # type: ignore[assignment]
    try:
        resp = await client.chat.completions.create(
            model=MODEL_NAME,
            messages=[
                {"role": "system", "content": reason_prompt},
                {"role": "user", "content": text},
            ],
            temperature=0.0,
            max_tokens=MAX_REASON_TOKENS,
        )
    except Exception:
        logger.exception("Stage2 reason generation failed")
        return ""

    return _clean_reason(resp.choices[0].message.content or "")
