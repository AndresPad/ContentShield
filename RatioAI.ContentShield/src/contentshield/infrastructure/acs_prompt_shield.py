"""Azure Content Safety Prompt Shield detector adapter."""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx
from azure.core.exceptions import ClientAuthenticationError
from azure.identity import CredentialUnavailableError

from contentshield.auth import cognitive_services_headers
from contentshield.config import get_acs_config
from contentshield.domain.models import DetectorResult, DetectorStatus

DETECTOR_NAME = "acs_prompt_shield"
_ATTACK_TYPE = "prompt_injection"

logger = logging.getLogger(__name__)

class _InvalidACSResponseError(Exception):
    """Raised when ACS returns an unexpected response shape."""


async def detect(text: str) -> DetectorResult:
    """Run Azure Content Safety Prompt Shield against the supplied text."""
    config = get_acs_config()
    if config is None:
        return DetectorResult.skipped(DETECTOR_NAME)

    started = time.perf_counter()
    url = (
        f"{config.endpoint}/contentsafety/text:shieldPrompt"
        f"?api-version={config.api_version}"
    )
    payload = {"userPrompt": text, "documents": []}

    try:
        headers = await cognitive_services_headers(config.api_key)
    except (ClientAuthenticationError, CredentialUnavailableError, RuntimeError) as exc:
        logger.exception("ACS auth failed")
        return _failed(str(exc), _elapsed_ms(started))
    except Exception as exc:
        logger.exception("ACS auth unexpected error")
        return _failed(str(exc), _elapsed_ms(started))

    try:
        async with httpx.AsyncClient(timeout=config.timeout_s) as client:
            response = await client.post(url, headers=headers, json=payload)
        response.raise_for_status()
        body = response.json()
        attack_detected = _extract_attack_detected(body)
    except (TimeoutError, httpx.TimeoutException):
        return DetectorResult.timed_out(DETECTOR_NAME, _elapsed_ms(started))
    except (httpx.HTTPStatusError, httpx.RequestError) as exc:
        logger.exception("ACS request failed")
        return _failed(str(exc), _elapsed_ms(started))
    except (ValueError, _InvalidACSResponseError) as exc:
        logger.exception("ACS response invalid")
        return _failed(str(exc), _elapsed_ms(started))
    except Exception as exc:
        logger.exception("ACS internal error")
        return _failed(str(exc), _elapsed_ms(started))

    return DetectorResult(
        name=DETECTOR_NAME,
        detected=attack_detected,
        label="INJECTION" if attack_detected else "SAFE",
        score=1.0 if attack_detected else 0.0,
        status=DetectorStatus.COMPLETED,
        latency_ms=_elapsed_ms(started),
        attack_type=_ATTACK_TYPE if attack_detected else None,
        reason=_reason_for_attack_detected(attack_detected),
    )


def _extract_attack_detected(body: Any) -> bool:
    """Extract the ACS user prompt attack flag from a response body."""
    if not isinstance(body, dict):
        raise _InvalidACSResponseError("ACS response body is not an object")

    user_prompt_analysis = body.get("userPromptAnalysis")
    if not isinstance(user_prompt_analysis, dict):
        raise _InvalidACSResponseError("ACS response missing userPromptAnalysis")

    attack_detected = user_prompt_analysis.get("attackDetected")
    if not isinstance(attack_detected, bool):
        raise _InvalidACSResponseError("ACS response missing attackDetected")

    return attack_detected


def _reason_for_attack_detected(attack_detected: bool) -> str:
    if attack_detected:
        return (
            "Azure Content Safety Prompt Shield detected a direct prompt "
            "injection attack in the user prompt."
        )
    return (
        "Azure Content Safety Prompt Shield did not detect a direct prompt "
        "injection attack in the user prompt."
    )


def _failed(error: str, latency_ms: int) -> DetectorResult:
    """Create a failed detector result with adapter-specific reason details."""
    return DetectorResult(
        name=DETECTOR_NAME,
        detected=False,
        label="SAFE",
        score=0.0,
        status=DetectorStatus.FAILED,
        latency_ms=latency_ms,
        error=error,
    )


def _elapsed_ms(started: float) -> int:
    """Return elapsed time in milliseconds."""
    return round((time.perf_counter() - started) * 1000)
