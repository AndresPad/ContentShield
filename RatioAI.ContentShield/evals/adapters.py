"""Adapters from /v1/detect payloads into eval runner result fields."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

EvalVerdict = Literal["INJECTION", "OK", "UNKNOWN"]
DetectorStatus = Literal["completed", "failed", "timed_out", "skipped"]

_VALID_DETECTOR_STATUSES = {"completed", "failed", "timed_out", "skipped"}


@dataclass(frozen=True)
class DetectorEvalEvidence:
    """Per-detector evidence surfaced by /v1/detect."""

    name: str
    detected: bool
    score: float
    status: DetectorStatus
    label: str = "SAFE"
    reason: str | None = None
    attack_type: str | None = None
    latency_ms: float | None = None

    def as_result_dict(self) -> dict:
        """Return the eval runner's legacy detector row shape."""
        return {
            "detected": self.detected,
            "score": self.score,
            "latency_ms": self.latency_ms or 0,
            "label": self.label,
            "status": self.status,
            "reason": self.reason,
            "attack_type": self.attack_type,
        }


@dataclass(frozen=True)
class EvalScore:
    """Normalized score fields used by the eval runners."""

    verdict: EvalVerdict
    score: float
    degraded: bool = False
    detectors: dict[str, DetectorEvalEvidence] = field(default_factory=dict)
    raw_output: str = ""
    error: str | None = None
    source: str = ""
    logprob_extracted: bool = False

    @property
    def predicted_label(self) -> str:
        """Return the label expected by existing metrics code."""
        return self.verdict

    @property
    def detector_status_counts(self) -> dict[str, int]:
        """Count normalized detector statuses."""
        counts: dict[str, int] = {}
        for evidence in self.detectors.values():
            counts[evidence.status] = counts.get(evidence.status, 0) + 1
        return counts

    @property
    def incomplete_detectors(self) -> list[str]:
        """Return detector names that did not complete."""
        return [name for name, evidence in self.detectors.items() if evidence.status != "completed"]

    @property
    def detector_reasons(self) -> dict[str, str | None]:
        """Return detector reason values by detector name."""
        return {name: evidence.reason for name, evidence in self.detectors.items()}


def adapt_detect_response(data: dict[str, Any], *, source: str = "detect") -> EvalScore:
    """Normalize a ContentShield /v1/detect response."""
    try:
        raw_verdict = str(data["verdict"]).upper()
    except (KeyError, TypeError):
        return eval_error("invalid_response", source=source)

    verdict = _detect_verdict_to_eval(raw_verdict)
    detectors = _normalize_detector_evidence(data.get("detectors", {}))
    degraded = bool(data.get("degraded", False)) or any(
        evidence.status != "completed" for evidence in detectors.values()
    )

    return EvalScore(
        verdict=verdict,
        score=_clamp_score(data.get("score", 0.0)),
        degraded=degraded or verdict == "UNKNOWN",
        detectors=detectors,
        raw_output=raw_verdict,
        error="invalid_response" if verdict == "UNKNOWN" else None,
        source=source,
        logprob_extracted=True,
    )


def eval_error(error: str, *, source: str = "", raw_output: str = "") -> EvalScore:
    """Create a degraded UNKNOWN score for failed calls or invalid payloads."""
    return EvalScore(
        verdict="UNKNOWN",
        score=0.0,
        degraded=True,
        raw_output=raw_output or f"ERROR: {error}",
        error=error,
        source=source,
        logprob_extracted=False,
    )


def _detect_verdict_to_eval(raw_verdict: str) -> EvalVerdict:
    if raw_verdict == "INJECTION":
        return "INJECTION"
    if raw_verdict == "SAFE":
        return "OK"
    return "UNKNOWN"


def _normalize_detector_evidence(raw_detectors: Any) -> dict[str, DetectorEvalEvidence]:
    if not isinstance(raw_detectors, dict):
        return {}

    detectors = {}
    for name, raw_evidence in raw_detectors.items():
        if not isinstance(raw_evidence, dict):
            detectors[str(name)] = DetectorEvalEvidence(
                name=str(name),
                detected=False,
                score=0.0,
                status="failed",
                reason="invalid_response",
            )
            continue

        status = _normalize_detector_status(raw_evidence.get("status"))
        label = str(raw_evidence.get("label", "SAFE")).upper()
        detectors[str(name)] = DetectorEvalEvidence(
            name=str(name),
            detected=status == "completed" and bool(raw_evidence.get("detected", label == "INJECTION")),
            score=_clamp_score(raw_evidence.get("score", 0.0)),
            status=status,
            label=label,
            reason=raw_evidence.get("reason"),
            attack_type=raw_evidence.get("attack_type"),
            latency_ms=raw_evidence.get("latency_ms"),
        )
    return detectors


def _normalize_detector_status(value: Any) -> DetectorStatus:
    status = str(value or "completed").lower()
    if status in _VALID_DETECTOR_STATUSES:
        return status  # type: ignore[return-value]
    return "failed"


def _clamp_score(value: Any) -> float:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return 0.0
    return min(1.0, max(0.0, score))
