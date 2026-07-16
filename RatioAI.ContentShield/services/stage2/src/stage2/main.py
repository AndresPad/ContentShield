"""ContentShield Stage-2 classifier wrapper.

Thin FastAPI service that fronts either a local vLLM server or Azure OpenAI.
Loads the configured prompt at startup and exposes a shared POST /classify contract.
"""

from __future__ import annotations

import asyncio
import json
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

STAGE2_BACKEND = os.environ.get("STAGE2_BACKEND", "vllm").strip().lower()
if STAGE2_BACKEND not in {"vllm", "azure_openai"}:
    raise RuntimeError(
        f"Invalid STAGE2_BACKEND={STAGE2_BACKEND!r}; expected 'vllm' or 'azure_openai'"
    )

VLLM_URL = os.environ.get("VLLM_URL", "http://localhost:8000").rstrip("/")
VLLM_HEALTH_URL = os.environ.get("VLLM_HEALTH_URL", f"{VLLM_URL}/health").rstrip("/")
PROMPT_PATH = os.environ.get(
    "PROMPT_PATH", "/workspace/prompts/pi-classifier-v6.txt"
)
CLASSIFIER_PROMPT_TEXT = os.environ.get("CLASSIFIER_PROMPT_TEXT")
MODEL_NAME = os.environ.get("MODEL_NAME", "google/gemma-4-31b-it")
VLLM_TIMEOUT_S = float(os.environ.get("VLLM_TIMEOUT_S", "30"))
AZURE_OPENAI_ENDPOINT = os.environ.get("AZURE_OPENAI_ENDPOINT", "").rstrip("/")
AZURE_OPENAI_DEPLOYMENT = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o").strip()
AZURE_OPENAI_API_VERSION = os.environ.get(
    "AZURE_OPENAI_API_VERSION", "2024-10-21"
).strip()
AZURE_OPENAI_API_KEY = os.environ.get("AZURE_OPENAI_API_KEY", "").strip()
AZURE_OPENAI_BEARER_TOKEN = os.environ.get(
    "AZURE_OPENAI_BEARER_TOKEN", ""
).strip()
AZURE_OPENAI_TIMEOUT_S = float(os.environ.get("AZURE_OPENAI_TIMEOUT_S", "3"))
AZURE_OPENAI_SCOPE = "https://cognitiveservices.azure.com/.default"
_AOAI_MAX_RETRIES_RAW = os.environ.get("AZURE_OPENAI_MAX_RETRIES", "1")
try:
    AZURE_OPENAI_MAX_RETRIES = int(_AOAI_MAX_RETRIES_RAW)
except ValueError as exc:
    raise RuntimeError(
        f"Invalid AZURE_OPENAI_MAX_RETRIES={_AOAI_MAX_RETRIES_RAW!r}; "
        "must be an integer"
    ) from exc
if not 0 <= AZURE_OPENAI_MAX_RETRIES <= 3:
    raise RuntimeError("AZURE_OPENAI_MAX_RETRIES must be between 0 and 3")
_AOAI_TOP_LOGPROBS_RAW = os.environ.get("AZURE_OPENAI_TOP_LOGPROBS", "10")
try:
    AZURE_OPENAI_TOP_LOGPROBS = int(_AOAI_TOP_LOGPROBS_RAW)
except ValueError as exc:
    raise RuntimeError(
        f"Invalid AZURE_OPENAI_TOP_LOGPROBS={_AOAI_TOP_LOGPROBS_RAW!r}; "
        "must be an integer"
    ) from exc
if not 2 <= AZURE_OPENAI_TOP_LOGPROBS <= 20:
    raise RuntimeError("AZURE_OPENAI_TOP_LOGPROBS must be between 2 and 20")
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


def _parse_label(content: str) -> str | None:
    first_token = content.strip().split(None, 1)[0] if content.strip() else ""
    normalized = _normalize_token(first_token)
    return normalized if normalized in {"YES", "NO"} else None


def _extract_yes_no_logprobs(choice: Any) -> tuple[float, float]:
    """Pull YES/NO logprobs from the first generated token.

    The classifier prompt makes YES/NO the dominant first-token candidates, so
    both usually appear in the sampled token and/or top_logprobs of a single
    call. Returns (lp_yes, lp_no). Raises _LogprobError when both calibrated
    candidates are not available; inventing the missing probability would make
    the public score appear more certain than the model output supports.
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


def _get_field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value.get(name)
    return getattr(value, name, None)


async def _score_with_prompt_logprobs(
    text: str,
    client: AsyncOpenAI,
    system_prompt: str,
) -> float:
    """Compute P(YES) by scoring candidates after the rendered chat prefix."""
    prompt_token_ids = await _render_chat_token_ids(text, system_prompt)
    lp_yes, lp_no = await asyncio.gather(
        _candidate_prompt_logprob(prompt_token_ids, client, "YES"),
        _candidate_prompt_logprob(prompt_token_ids, client, "NO"),
    )
    return _softmax_two(lp_yes, lp_no)


async def _render_chat_token_ids(text: str, system_prompt: str) -> list[int]:
    """Render the exact vLLM chat template used by the primary model call."""
    client: httpx.AsyncClient = _state["vllm_http_client"]  # type: ignore[assignment]
    response = await client.post(
        "/v1/chat/completions/render",
        json={
            "model": MODEL_NAME,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            "max_tokens": 1,
        },
    )
    response.raise_for_status()
    token_ids = response.json().get("token_ids")
    if not isinstance(token_ids, list) or not token_ids or not all(
        isinstance(token_id, int) for token_id in token_ids
    ):
        raise _LogprobError("vLLM render response missing token_ids")
    return token_ids


async def _candidate_prompt_logprob(
    prompt_token_ids: list[int],
    client: AsyncOpenAI,
    candidate: str,
) -> float:
    """Read the prompt logprob of one appended YES/NO candidate."""
    candidate_token_ids: dict[str, int] = _state[  # type: ignore[assignment]
        "vllm_candidate_token_ids"
    ]
    resp = await client.completions.create(
        model=MODEL_NAME,
        prompt=[*prompt_token_ids, candidate_token_ids[candidate]],
        temperature=0.0,
        max_tokens=1,
        extra_body={"prompt_logprobs": 20},
    )

    prompt_logprobs = _get_field(resp.choices[0], "prompt_logprobs")
    if not prompt_logprobs:
        raise _LogprobError(f"prompt_logprobs missing for {candidate}")

    for token_logprobs in reversed(prompt_logprobs):
        if not token_logprobs:
            continue
        for entry in token_logprobs.values():
            decoded = _get_field(entry, "decoded_token")
            logprob = _get_field(entry, "logprob")
            if not isinstance(decoded, str) or not isinstance(logprob, (int, float)):
                continue
            if _normalize_token(decoded) == candidate:
                return float(logprob)

    raise _LogprobError(f"prompt_logprobs missing candidate {candidate}")


async def _load_vllm_candidate_token_ids(
    client: httpx.AsyncClient,
) -> dict[str, int]:
    """Resolve and validate the one-token YES/NO labels for the active model."""
    labels = ("YES", "NO")
    responses = await asyncio.gather(
        *(
            client.post(
                "/tokenize",
                json={
                    "model": MODEL_NAME,
                    "prompt": label,
                    "add_special_tokens": False,
                },
            )
            for label in labels
        )
    )
    token_ids: dict[str, int] = {}
    for label, response in zip(labels, responses, strict=True):
        response.raise_for_status()
        tokens = response.json().get("tokens")
        if not isinstance(tokens, list) or len(tokens) != 1 or not isinstance(
            tokens[0], int
        ):
            raise RuntimeError(f"Stage2 label {label} must tokenize to one token")
        token_ids[label] = tokens[0]
    return token_ids


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


async def _azure_openai_token_provider() -> str:
    """Return an Azure OpenAI bearer token from the configured credential."""
    credential = _state["credential"]
    access_token = await credential.get_token(AZURE_OPENAI_SCOPE)
    return access_token.token


async def _create_azure_openai_client() -> object:
    """Create the Azure-aware OpenAI client and warm managed identity."""
    from openai import AsyncAzureOpenAI

    auth: dict[str, object]
    if AZURE_OPENAI_API_KEY:
        auth = {"api_key": AZURE_OPENAI_API_KEY}
    elif AZURE_OPENAI_BEARER_TOKEN:
        auth = {"azure_ad_token": AZURE_OPENAI_BEARER_TOKEN}
    else:
        from azure.identity.aio import DefaultAzureCredential

        credential = DefaultAzureCredential()
        _state["credential"] = credential
        await credential.get_token(AZURE_OPENAI_SCOPE)
        auth = {"azure_ad_token_provider": _azure_openai_token_provider}

    return AsyncAzureOpenAI(
        azure_endpoint=AZURE_OPENAI_ENDPOINT,
        azure_deployment=AZURE_OPENAI_DEPLOYMENT,
        api_version=AZURE_OPENAI_API_VERSION,
        timeout=AZURE_OPENAI_TIMEOUT_S,
        max_retries=AZURE_OPENAI_MAX_RETRIES,
        **auth,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load prompts and prepare the selected Stage2 backend."""
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

    if STAGE2_BACKEND == "vllm":
        _state["client"] = AsyncOpenAI(
            base_url=f"{VLLM_URL}/v1",
            api_key="EMPTY",  # vLLM ignores the key by default
            timeout=VLLM_TIMEOUT_S,
        )
        vllm_http_client = httpx.AsyncClient(
            base_url=VLLM_URL,
            timeout=VLLM_TIMEOUT_S,
        )
        _state["vllm_http_client"] = vllm_http_client
        _state["vllm_candidate_token_ids"] = (
            await _load_vllm_candidate_token_ids(vllm_http_client)
        )
    else:
        if not AZURE_OPENAI_ENDPOINT:
            raise RuntimeError(
                "AZURE_OPENAI_ENDPOINT is required when STAGE2_BACKEND=azure_openai"
            )
        if not AZURE_OPENAI_DEPLOYMENT:
            raise RuntimeError(
                "AZURE_OPENAI_DEPLOYMENT is required when STAGE2_BACKEND=azure_openai"
            )
        _state["client"] = await _create_azure_openai_client()

    system_prompt: str = _state["system_prompt"]  # type: ignore[assignment]
    logger.info(
        "Stage2 wrapper ready: backend=%s prompt=%d chars",
        STAGE2_BACKEND,
        len(system_prompt),
    )
    try:
        yield
    finally:
        client = _state.get("client")
        if STAGE2_BACKEND == "azure_openai" and client is not None:
            await client.close()
        vllm_http_client = _state.get("vllm_http_client")
        if isinstance(vllm_http_client, httpx.AsyncClient):
            await vllm_http_client.aclose()
        credential = _state.get("credential")
        if credential is not None:
            await credential.close()
        _state.clear()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    """Return readiness for the configured Stage2 backend."""
    if STAGE2_BACKEND == "azure_openai":
        if "client" not in _state:
            raise HTTPException(503, detail="azure_openai_not_ready")
        return {
            "status": "ok",
            "service": "stage2",
            "backend": "azure_openai",
        }

    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(VLLM_HEALTH_URL)
        if r.status_code != 200:
            raise HTTPException(503, detail="vllm_unhealthy")
    except httpx.RequestError as exc:
        raise HTTPException(503, detail="vllm_unreachable") from exc
    return {"status": "ok", "service": "stage2", "backend": "vllm"}


@app.post("/classify", response_model=ClassifyResponse)
async def classify(req: ClassifyRequest) -> ClassifyResponse:
    """Classify user text and return label + P(YES) probabilistic score."""
    if STAGE2_BACKEND == "azure_openai":
        return await _classify_azure_openai(req.text)

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
    content = (choice.message.content or "") if choice.message else ""
    label = _parse_label(content)
    if label is None:
        logger.error("Stage2 invalid response: %r", content)
        raise HTTPException(502, detail="invalid_response")

    # Prefer single-call scoring when vLLM returns both generated-token
    # candidates. Some stable vLLM/model combinations return only the sampled
    # candidate, so fall back to scoring the two answer prompts directly.
    try:
        lp_yes, lp_no = _extract_yes_no_logprobs(choice)
        score = _softmax_two(lp_yes, lp_no)
    except _LogprobError as exc:
        logger.warning(
            "Stage2 generated-token logprobs incomplete; using prompt-logprob "
            "fallback: %s",
            exc,
        )
        try:
            score = await _score_with_prompt_logprobs(
                req.text,
                client,
                system_prompt,
            )
        except _LogprobError as fallback_exc:
            # Fail closed: surface missing probabilities instead of inventing a
            # SAFE result or an exact 0/1 score.
            logger.error("Stage2 logprob extraction failed: %s", fallback_exc)
            raise HTTPException(502, detail="logprobs_unavailable") from fallback_exc
        except Exception as fallback_exc:
            logger.exception("vLLM prompt-logprob fallback failed")
            raise HTTPException(502, detail="vllm_call_failed") from fallback_exc

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


async def _classify_azure_openai(text: str) -> ClassifyResponse:
    """Classify text through GPT-4o hosted on Azure OpenAI."""
    from openai import APIConnectionError, APIError, APITimeoutError, BadRequestError

    client = _state["client"]
    system_prompt: str = _state["system_prompt"]  # type: ignore[assignment]
    try:
        response = await client.chat.completions.create(
            model=AZURE_OPENAI_DEPLOYMENT,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            temperature=0.0,
            max_tokens=12,
            logprobs=True,
            top_logprobs=AZURE_OPENAI_TOP_LOGPROBS,
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "prompt_injection_verdict",
                    "strict": True,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "answer": {"type": "string", "enum": ["YES", "NO"]}
                        },
                        "required": ["answer"],
                        "additionalProperties": False,
                    },
                },
            },
        )
    except BadRequestError as exc:
        filter_verdict = _azure_content_filter_verdict(exc.response)
        if filter_verdict is not None:
            label = "YES" if filter_verdict else "NO"
            reason = (
                "Azure OpenAI content filtering detected a jailbreak attempt."
                if filter_verdict
                else "Azure OpenAI blocked non-jailbreak content."
            )
            return ClassifyResponse(
                injection=filter_verdict,
                label=label,
                score=1.0 if filter_verdict else 0.0,
                reason=reason,
            )
        logger.exception("Azure OpenAI rejected the classification request")
        raise HTTPException(502, detail="azure_openai_call_failed") from exc
    except (APIConnectionError, APITimeoutError) as exc:
        logger.exception("Azure OpenAI call failed")
        raise HTTPException(502, detail="azure_openai_unreachable") from exc
    except APIError as exc:
        logger.exception("Azure OpenAI classification failed")
        raise HTTPException(502, detail="azure_openai_call_failed") from exc

    try:
        label, score = _parse_azure_openai_response(response.model_dump())
    except (ValueError, KeyError, TypeError, _LogprobError) as exc:
        logger.exception("Azure OpenAI classification failed")
        raise HTTPException(502, detail="azure_openai_call_failed") from exc

    return ClassifyResponse(
        injection=label == "YES",
        label=label,
        score=score,
        reason="",
    )


def _parse_azure_openai_response(body: dict[str, Any]) -> tuple[str, float]:
    try:
        choice = body["choices"][0]
        content = choice["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError("Azure OpenAI response is missing completion content") from exc

    try:
        parsed = json.loads(content)
        label = parsed["answer"].strip().upper()
    except (json.JSONDecodeError, KeyError, AttributeError, TypeError) as exc:
        raise ValueError("Azure OpenAI response is not a valid verdict object") from exc
    if label not in {"YES", "NO"}:
        raise ValueError("Azure OpenAI response verdict is not YES or NO")

    lp_yes, lp_no = _extract_azure_yes_no_logprobs(choice)
    score = _softmax_two(lp_yes, lp_no)
    if (score >= 0.5) != (label == "YES"):
        raise ValueError("Azure OpenAI verdict and log probabilities disagree")
    return label, score


def _extract_azure_yes_no_logprobs(choice: dict[str, Any]) -> tuple[float, float]:
    try:
        content = choice["logprobs"]["content"]
    except (KeyError, TypeError) as exc:
        raise _LogprobError("logprobs missing from Azure OpenAI response") from exc
    if not isinstance(content, list):
        raise _LogprobError("logprobs.content missing from Azure OpenAI response")

    for token_info in content:
        if not isinstance(token_info, dict):
            continue
        candidates: dict[str, float] = {}
        token = token_info.get("token")
        logprob = token_info.get("logprob")
        if isinstance(token, str) and isinstance(logprob, (int, float)):
            normalized = _normalize_token(token)
            if normalized in {"YES", "NO"}:
                candidates[normalized] = float(logprob)

        for entry in token_info.get("top_logprobs") or []:
            if not isinstance(entry, dict):
                continue
            candidate = entry.get("token")
            candidate_logprob = entry.get("logprob")
            if not isinstance(candidate, str) or not isinstance(
                candidate_logprob, (int, float)
            ):
                continue
            normalized = _normalize_token(candidate)
            if normalized in {"YES", "NO"} and normalized not in candidates:
                candidates[normalized] = float(candidate_logprob)

        if "YES" in candidates and "NO" in candidates:
            return candidates["YES"], candidates["NO"]

    raise _LogprobError("Azure OpenAI logprobs missing YES or NO candidate")


def _azure_content_filter_verdict(response: httpx.Response) -> bool | None:
    """Map an explicit Azure content-filter result to prompt-injection intent.

    Azure can block a request before GPT-4o runs. An explicit jailbreak signal
    is an injection. If the request is blocked for another harm category and
    the response explicitly says jailbreak was not detected, it is not prompt
    injection. Missing or ambiguous filter evidence remains a backend failure.
    """
    try:
        error = response.json().get("error", {})
    except ValueError:
        return None
    if error.get("code") != "content_filter":
        return None
    inner = error.get("innererror") or error.get("inner_error") or {}
    filter_result = (
        inner.get("content_filter_result")
        or inner.get("content_filter_results")
        or {}
    )
    jailbreak = filter_result.get("jailbreak") or {}
    if jailbreak.get("detected") is True and jailbreak.get("filtered") is True:
        return True
    if jailbreak.get("detected") is False:
        return False
    return None
