"""Mappers between API models and domain models.

One-way dependency: this module imports both ``api.models`` and
``domain.models``. Neither of those imports the other.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from contentshield.api.models import (
    DetectorEvidence,
    DetectRequest,
    DetectResponse,
)
from contentshield.domain.models import (
    DetectionCommand,
    DetectionMode,
    DetectionResponse,
    DetectorResult,
    DetectorStatus,
)

if TYPE_CHECKING:
    from collections.abc import Iterable


def request_to_command(request: DetectRequest) -> DetectionCommand:
    """Map an HTTP request model to a domain command."""
    return DetectionCommand(
        text=request.text,
        mode=DetectionMode(request.mode),
        documents=request.documents,
        detector_override=request.detectors,
        # No-op when CONTENTSHIELD_V1_ML_DISABLED=1 (default); preserved for schema stability.
        enable_query_detection=request.options.enable_query_detection,
        request_metadata=request.metadata,
    )


def response_to_model(response: DetectionResponse) -> DetectResponse:
    """Map a domain response to the compact HTTP response contract."""
    completed_results = [
        r for r in response.detectors.values()
        if r.status == DetectorStatus.COMPLETED
    ]
    attack_types = sorted({
        r.attack_type
        for r in completed_results
        if r.attack_type is not None
    })
    return DetectResponse(
        request_id=response.request_id,
        verdict=response.verdict.value,
        score=_top_score(completed_results),
        degraded=any(
            r.status != DetectorStatus.COMPLETED
            for r in response.detectors.values()
        ),
        attack_types=attack_types,
        detectors={
            name: _result_to_evidence(r)
            for name, r in response.detectors.items()
        },
    )


def _top_score(results: Iterable[DetectorResult]) -> float:
    """Return the strongest score from visible detector results."""
    scores = [r.score for r in results]
    return max(scores, default=0.0)


def _result_to_evidence(r: DetectorResult) -> DetectorEvidence:
    """Map a single domain detector result to its evidence model."""
    return DetectorEvidence(
        label=r.label,
        score=r.score,
        status=r.status.value,
        attack_type=r.attack_type,
        reason=r.reason if r.status == DetectorStatus.COMPLETED else None,
    )
