"""Pydantic models for the orchestrator HTTP API.

These models define the public contract for ``POST /v1/detect`` and
``GET /health``. Pydantic stays in this layer only — domain models
are stdlib dataclasses.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_serializer

# -- Request --

class DetectOptions(BaseModel):
    """Optional flags on a detect request."""

    model_config = ConfigDict(extra="forbid")

    # No-op when CONTENTSHIELD_V1_ML_DISABLED=1 (default V1). Field retained for
    # request-schema stability; effective again when query_detect is rewired.
    enable_query_detection: bool = False


class DetectRequest(BaseModel):
    """POST /v1/detect request body."""

    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, description="User prompt to classify.")
    mode: Literal["fast", "standard", "deep"] = "standard"
    documents: list[str] = Field(default_factory=list)
    detectors: list[str] | None = None
    options: DetectOptions = Field(default_factory=DetectOptions)
    metadata: dict[str, str] = Field(default_factory=dict)

    @field_validator("text")
    @classmethod
    def text_must_not_be_blank(cls, value: str) -> str:
        """Trim and reject blank prompts."""
        text = value.strip()
        if not text:
            raise ValueError("text must not be blank")
        return text


# -- Response --

class LatencyEnvelope(BaseModel):
    """Top-level latency envelope. Emitted only when ``X-Include-Latency`` is set."""

    end_to_end: int


class DetectorEvidence(BaseModel):
    """Compact per-detector evidence in the response."""

    label: Literal["INJECTION", "SAFE"]
    score: float = Field(ge=0.0, le=1.0)
    status: Literal["completed", "failed", "timed_out", "skipped"]
    attack_type: str | None = None
    reason: str | None = None
    # Per-detector wall-clock latency. Emitted only when the caller sent
    # ``X-Include-Latency``; otherwise dropped at serialization so the v1.0.1
    # response stays byte-identical for legacy consumers.
    latency_ms: int | None = None

    @model_serializer(mode="wrap")
    def _drop_none_latency(self, handler) -> dict[str, Any]:
        data = handler(self)
        if data.get("latency_ms") is None:
            data.pop("latency_ms", None)
        return data


class DetectResponse(BaseModel):
    """POST /v1/detect response body.

    ``verdict=SAFE`` means no completed detector found injection evidence.
    ``degraded=true`` means the decision was made with incomplete detector
    coverage.
    """

    request_id: str
    verdict: Literal["INJECTION", "SAFE"]
    score: float = Field(ge=0.0, le=1.0)
    degraded: bool
    attack_types: list[str] = Field(default_factory=list)
    detectors: dict[str, DetectorEvidence]
    # See ``DetectorEvidence.latency_ms``: only present when opt-in header is set.
    latency_ms: LatencyEnvelope | None = None

    @model_serializer(mode="wrap")
    def _drop_none_latency(self, handler) -> dict[str, Any]:
        data = handler(self)
        if data.get("latency_ms") is None:
            data.pop("latency_ms", None)
        return data


# -- Health --

class HealthResponse(BaseModel):
    """GET /health response body."""

    status: Literal["ok"] = "ok"
    service: Literal["contentshield"] = "contentshield"
