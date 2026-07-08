"""ContentShield Stage-2 classifier wrapper.

Thin FastAPI service that fronts a local vLLM OpenAI-compatible server.
Loads the v6 prompt at startup, exposes a clean POST /classify contract.
"""

from __future__ import annotations

import logging
import math
import os
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

VLLM_URL = os.environ.get("VLLM_URL", "http://localhost:8000").rstrip("/")
VLLM_HEALTH_URL = os.environ.get("VLLM_HEALTH_URL", f"{VLLM_URL}/health").rstrip("/")
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
ENABLE_STAGE2_REASON = os.environ.get("ENABLE_STAGE2_REASON", "true").strip().lower() in {
    "1",
    "true",
    "yes",
}
_MAX_REASON_TOKENS_RAW = os.environ.get("MAX_REASON_TOKENS", "256")
MAX_REASON_TOKENS = 256
if ENABLE_STAGE2_REASON:
    try:
        MAX_REASON_TOKENS = int(_MAX_REASON_TOKENS_RAW)
    except ValueError as exc:
        raise RuntimeError(
            f"Invalid MAX_REASON_TOKENS={_MAX_REASON_TOKENS_RAW!r}; must be an integer"
        ) from exc


class ClassifyRequest(BaseModel):
    """Request body for Stage-2 prompt-injection classification."""

    text: str = Field(..., min_length=1)


class ClassifyResponse(BaseModel):
    """Stage-2 classification result with probabilistic injection score."""

    injection: bool
    label: str  # "YES" | "NO"
    score: float = Field(..., ge=0.0, le=1.0)  # P(YES) from softmax over YES/NO logprobs
    reason: str = Field(default="", max_length=200)


class _LogprobError(Exception):
    """Raised when YES/NO logprobs cannot be extracted from a vLLM response."""


_state: dict[str, object] = {}


def _normalize_token(token: str) -> str:
    return token.strip(" \t\r\n.,;:!?\"'`()[]{}").upper()


def _extract_yes_no_logprobs(choice: Any) -> tuple[float, float]:
    """Pull YES/NO logprobs from the first generated token.

    The classifier prompt makes YES/NO the dominant first-token candidates, so
    both usually appear in the sampled token and/or top_logprobs of a single
    call. vLLM can still report only the sampled constrained token; in that
    case the other probability is the complement, so represent it as log(0).
    Returns (lp_yes, lp_no). Raises _LogprobError when neither is available.
    """
    logprobs = getattr(choice, "logprobs", None)
    if logprobs is None:
        raise _LogprobError("logprobs missing from response")

    content = getattr(logprobs, "content", None)
    if not content:
        raise _LogprobError("logprobs.content missing or empty")

    first = content[0]
    candidates: dict[str, float] = {}

    sampled_token = getattr(first, "token", None)
    sampled_logprob = getattr(first, "logprob", None)
    if isinstance(sampled_token, str) and isinstance(sampled_logprob, (int, float)):
        normalized = _normalize_token(sampled_token)
        if normalized in {"YES", "NO"}:
            candidates[normalized] = float(sampled_logprob)

    for entry in getattr(first, "top_logprobs", None) or []:
        token = getattr(entry, "token", None)
        lp = getattr(entry, "logprob", None)
        if not isinstance(token, str) or not isinstance(lp, (int, float)):
            continue
        normalized = _normalize_token(token)
        if normalized in {"YES", "NO"} and normalized not in candidates:
            candidates[normalized] = float(lp)

    if "YES" in candidates and "NO" not in candidates:
        return candidates["YES"], -math.inf
    if "NO" in candidates and "YES" not in candidates:
        return -math.inf, candidates["NO"]

    if "YES" not in candidates or "NO" not in candidates:
        raise _LogprobError(
            f"top_logprobs missing YES or NO: found={sorted(candidates)}"
        )

    return candidates["YES"], candidates["NO"]


def _softmax_two(lp_yes: float, lp_no: float) -> float:
    """Numerically stable softmax over two logprobs; returns P(YES)."""
    m = max(lp_yes, lp_no)
    e_yes = math.exp(lp_yes - m)
    e_no = math.exp(lp_no - m)
    return e_yes / (e_yes + e_no)


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
            r = await client.get(VLLM_HEALTH_URL)
        if r.status_code != 200:
            raise HTTPException(503, detail="vllm_unhealthy")
    except httpx.RequestError as exc:
        raise HTTPException(503, detail="vllm_unreachable") from exc
    return {"status": "ok", "service": "stage2"}


@app.post("/classify", response_model=ClassifyResponse)
async def classify(req: ClassifyRequest) -> ClassifyResponse:
    """Classify user text and return label + P(YES) probabilistic score."""
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
            max_tokens=1,
            logprobs=True,
            top_logprobs=20,
        )
    except Exception as exc:
        logger.exception("vLLM call failed")
        raise HTTPException(502, detail="vllm_call_failed") from exc

    choice = resp.choices[0]

    # Single-call probabilistic scoring: both YES and NO logprobs are read from
    # this one call's first-token top_logprobs, and P(NO) is simply 1 - P(YES)
    # via the two-way softmax — no extra model calls. guided_choice is omitted on
    # purpose: it masks the non-sampled token's logprob, which is what previously
    # forced two extra prompt-logprob calls (one per candidate) on every request.
    try:
        lp_yes, lp_no = _extract_yes_no_logprobs(choice)
    except _LogprobError as exc:
        # Fail closed: do NOT default to SAFE — surface the error so the wrapper
        # records this detector as FAILED rather than silently passing benign.
        logger.error("Stage2 logprob extraction failed: %s", exc)
        raise HTTPException(502, detail="logprobs_unavailable") from exc

    score = _softmax_two(lp_yes, lp_no)
    label = "YES" if lp_yes >= lp_no else "NO"

    if label == "YES":
        reason = await _generate_reason(req.text, client)
        return ClassifyResponse(injection=True, label="YES", score=score, reason=reason)
    return ClassifyResponse(injection=False, label="NO", score=score, reason="")


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
