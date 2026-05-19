"""Domain models for the orchestrator detection pipeline."""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from typing import Any, Literal


class DetectionMode(enum.StrEnum):
    """Canonical detection modes controlling layer depth."""

    FAST = "fast"
    STANDARD = "standard"
    DEEP = "deep"


class Verdict(enum.StrEnum):
    """Final detection verdict."""

    SAFE = "SAFE"
    INJECTION = "INJECTION"


class DetectorStatus(enum.StrEnum):
    """Outcome status for an individual detector invocation."""

    COMPLETED = "completed"
    TIMED_OUT = "timed_out"
    FAILED = "failed"
    SKIPPED = "skipped"


@dataclass(frozen=True)
class DetectorResult:
    """Normalized result from a single detector invocation."""

    name: str
    detected: bool
    label: Literal["INJECTION", "SAFE"]
    score: float  # 0.0 - 1.0
    status: DetectorStatus
    latency_ms: int = 0
    attack_type: str | None = None
    reason: str | None = None
    error: str | None = None
    details: dict[str, Any] | None = None

    def __post_init__(self) -> None:
        if not (0.0 <= self.score <= 1.0):
            msg = f"score must be 0.0-1.0, got {self.score}"
            raise ValueError(msg)

    @classmethod
    def failed(cls, name: str, error: str, latency_ms: int = 0) -> DetectorResult:
        """Create a result representing a detector failure."""
        return cls(
            name=name,
            detected=False,
            label="SAFE",
            score=0.0,
            status=DetectorStatus.FAILED,
            latency_ms=latency_ms,
            error=error,
        )

    @classmethod
    def timed_out(cls, name: str, latency_ms: int) -> DetectorResult:
        """Create a result representing a detector timeout."""
        return cls(
            name=name,
            detected=False,
            label="SAFE",
            score=0.0,
            status=DetectorStatus.TIMED_OUT,
            latency_ms=latency_ms,
            error="Detector timed out",
        )

    @classmethod
    def skipped(cls, name: str) -> DetectorResult:
        """Create a result representing a skipped detector."""
        return cls(
            name=name,
            detected=False,
            label="SAFE",
            score=0.0,
            status=DetectorStatus.SKIPPED,
        )


@dataclass
class LatencyBreakdown:
    """Timing data for the detection pipeline."""

    end_to_end: int = 0
    # Note: int keys serialize as strings in JSON. The API mapper
    # layer must handle this when building the HTTP response.
    by_layer: dict[int, int] = field(default_factory=dict)


@dataclass
class DetectionCommand:
    """Application-level input for the detection pipeline."""

    text: str
    mode: DetectionMode = DetectionMode.STANDARD
    documents: list[str] = field(default_factory=list)
    detector_override: list[str] | None = None
    enable_query_detection: bool = False
    request_metadata: dict[str, str] = field(default_factory=dict)


@dataclass
class DetectionResponse:
    """Application-level output from the detection pipeline."""

    request_id: str
    detected: bool
    verdict: Verdict
    mode: DetectionMode
    stopped_at_layer: int
    detectors: dict[str, DetectorResult]
    errors: dict[str, str]
    latency_ms: LatencyBreakdown
    reasons: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
