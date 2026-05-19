"""Single-layer detection pipeline.

All wired detectors run in parallel. The Stage2 SLM is the authoritative
verdict: when it completes, its ``detected`` value is the final verdict.
Other detectors run alongside as advisory signal and surface in the
per-detector results, but do not flip the verdict on their own. If every
attempted detector ends in ``FAILED``/``TIMED_OUT``, the pipeline fails
closed and forces ``INJECTION``.

Wiring is owned by ``infrastructure/detectors.py``; the pipeline is
agnostic to which detectors are present.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from collections.abc import Callable, Coroutine
from typing import Any

from contentshield.domain.errors import InvalidModeError
from contentshield.domain.models import (
    DetectionCommand,
    DetectionMode,
    DetectionResponse,
    DetectorResult,
    DetectorStatus,
    LatencyBreakdown,
    Verdict,
)

logger = logging.getLogger(__name__)

# Type alias for detector functions.
DetectFn = Callable[[str], Coroutine[Any, Any, DetectorResult]]

# Per-detector timeout budgets (seconds).
TIMEOUTS: dict[str, float] = {
    "acs_prompt_shield": 5.0,
    "stage1": 8.0,
    "query_detect": 0.1,
    "stage2": float(os.environ.get("STAGE2_DETECTOR_TIMEOUT_SECONDS", "8.0")),
}

# Default timeout for unknown detectors.
DEFAULT_TIMEOUT: float = 5.0

# Default-mode production verdict source.
AUTHORITATIVE_DETECTOR = "stage2"


async def _run_detector(
    name: str, fn: DetectFn, text: str, timeout: float
) -> DetectorResult:
    """Run a single detector with timeout and error handling.

    Returns a ``DetectorResult`` in all cases — never raises.
    """
    start_ns = time.monotonic_ns()
    try:
        result = await asyncio.wait_for(fn(text), timeout=timeout)
        return result
    except TimeoutError:
        elapsed_ms = (time.monotonic_ns() - start_ns) // 1_000_000
        logger.warning("Detector %s timed out after %dms", name, elapsed_ms)
        return DetectorResult.timed_out(name, elapsed_ms)
    except Exception as exc:
        elapsed_ms = (time.monotonic_ns() - start_ns) // 1_000_000
        logger.exception("Detector %s failed", name)
        return DetectorResult.failed(name, str(exc), elapsed_ms)


def _any_completed_detected(results: list[DetectorResult]) -> bool:
    """Return True if any completed detector flagged injection."""
    return any(
        r.detected and r.status == DetectorStatus.COMPLETED for r in results
    )


def _authoritative_detected(results: list[DetectorResult]) -> bool:
    """Return the completed authoritative detector verdict when present."""
    for result in results:
        if (
            result.name == AUTHORITATIVE_DETECTOR
            and result.status == DetectorStatus.COMPLETED
        ):
            return result.detected
    return False


async def run(
    command: DetectionCommand,
    detectors: dict[str, DetectFn],
) -> DetectionResponse:
    """Execute the detection pipeline against the wired detector set.

    Args:
        command: The detection request (text, mode, options).
        detectors: Dict mapping detector name to its async detect function.

    Returns:
        A ``DetectionResponse`` with per-detector results and verdict.

    Raises:
        InvalidModeError: If ``command.mode`` is ``deep`` (V2 only).
    """
    if command.mode == DetectionMode.FAST:
        raise InvalidModeError("fast", reason="fast path is not available in V1")
    if command.mode == DetectionMode.DEEP:
        raise InvalidModeError("deep", reason="LLM detector lands in V2")

    request_id = command.request_metadata.get(
        "request_id", str(uuid.uuid4())
    )
    start_ns = time.monotonic_ns()

    layer_latencies: dict[int, int] = {}
    stopped_at_layer = 0

    if command.detector_override:
        # Eval/diagnostic mode: run only the named detectors.
        results = await _run_override(
            command.text, command.detector_override, detectors
        )
    else:
        # Normal mode: run every wired detector in parallel.
        stopped_at_layer = 1
        layer_start = time.monotonic_ns()
        results = await _run_all(command.text, detectors)
        layer_latencies[1] = (time.monotonic_ns() - layer_start) // 1_000_000

    all_results: dict[str, DetectorResult] = {r.name: r for r in results}
    all_errors: dict[str, str] = {r.name: r.error for r in results if r.error}

    reasons: list[str] = []
    if command.detector_override:
        # Eval/diagnostic mode reflects the detectors explicitly requested.
        detected = _any_completed_detected(results)
    else:
        # Production/default mode uses Stage2 as the authoritative verdict.
        detected = _authoritative_detected(results)
    if detected:
        reasons.append("Injection detected")

    # Fail-closed: if every attempted detector failed/timed-out, force
    # INJECTION so callers see the degraded state in the verdict, not just
    # in the per-detector errors.
    completed_count = sum(
        1 for r in results if r.status == DetectorStatus.COMPLETED
    )
    failure_count = sum(
        1 for r in results
        if r.status in {DetectorStatus.FAILED, DetectorStatus.TIMED_OUT}
    )
    all_failed = (
        bool(results)
        and completed_count == 0
        and failure_count == len(results)
    )
    if all_failed:
        detected = True
        reasons.append("all_detectors_failed")

    return _build_response(
        request_id, detected, command, all_results,
        all_errors, layer_latencies, stopped_at_layer,
        reasons, start_ns,
    )


async def _run_all(
    text: str,
    detectors: dict[str, DetectFn],
) -> list[DetectorResult]:
    """Run every wired detector in parallel."""
    if not detectors:
        return []
    tasks = [
        _run_detector(name, fn, text, TIMEOUTS.get(name, DEFAULT_TIMEOUT))
        for name, fn in detectors.items()
    ]
    return list(await asyncio.gather(*tasks))


async def _run_override(
    text: str,
    names: list[str],
    detectors: dict[str, DetectFn],
) -> list[DetectorResult]:
    """Run only the explicitly named detectors (eval/diagnostic mode)."""
    results: list[DetectorResult] = []
    tasks: list[tuple[str, DetectFn]] = []

    # Unknown detector names in an override list are a caller config error,
    # not a routine skip. Mark them FAILED so they surface in the response
    # and contribute to the all-detectors-failed fail-closed check.
    for name in names:
        fn = detectors.get(name)
        if fn is None:
            results.append(
                DetectorResult.failed(name, f"detector {name} not configured")
            )
        else:
            tasks.append((name, fn))

    if tasks:
        gathered = await asyncio.gather(
            *[
                _run_detector(n, fn, text, TIMEOUTS.get(n, DEFAULT_TIMEOUT))
                for n, fn in tasks
            ]
        )
        results.extend(gathered)

    return results


def _build_response(
    request_id: str,
    detected: bool,
    command: DetectionCommand,
    detectors: dict[str, DetectorResult],
    errors: dict[str, str],
    layer_latencies: dict[int, int],
    stopped_at_layer: int,
    reasons: list[str],
    start_ns: int,
) -> DetectionResponse:
    """Assemble the final detection response."""
    end_to_end_ms = (time.monotonic_ns() - start_ns) // 1_000_000
    return DetectionResponse(
        request_id=request_id,
        detected=detected,
        verdict=Verdict.INJECTION if detected else Verdict.SAFE,
        mode=command.mode,
        stopped_at_layer=stopped_at_layer,
        detectors=detectors,
        errors=errors,
        latency_ms=LatencyBreakdown(
            end_to_end=end_to_end_ms,
            by_layer=layer_latencies,
        ),
        reasons=reasons,
        metadata={},
    )
