"""DetectorResult adapter for the Stage-1 residual classifier."""

from __future__ import annotations

import logging
import time

import httpx

from contentshield.domain.models import DetectorResult, DetectorStatus
from contentshield.infrastructure.stage1 import chunker
from contentshield.infrastructure.stage1.classifier import (
    MODEL_VERSION,
    InvalidClassifierInputError,
    Stage1Classification,
    classify,
)
from contentshield.infrastructure.stage1.embedder import (
    AOAIConfigMissingError,
    AOAIEmbeddingDependencyError,
    InvalidAOAIEmbeddingResponseError,
    embed_texts,
)

DETECTOR_NAME = "stage1"
_ATTACK_TYPE = "prompt_injection"

logger = logging.getLogger(__name__)


async def detect(text: str) -> DetectorResult:
    """Run Stage-1 residual prompt-injection detection."""
    chunks = chunker.chunk_text(text)
    if not chunks:
        return DetectorResult.skipped(DETECTOR_NAME)

    started = time.perf_counter()
    try:
        embeddings = await embed_texts(chunks)
        result = classify(embeddings)
    except AOAIConfigMissingError:
        return DetectorResult.skipped(DETECTOR_NAME)
    except (AOAIEmbeddingDependencyError, httpx.TimeoutException, TimeoutError) as exc:
        logger.exception("Stage1 dependency error")
        return _failed(str(exc), _elapsed_ms(started))
    except (InvalidAOAIEmbeddingResponseError, InvalidClassifierInputError) as exc:
        logger.exception("Stage1 invalid response")
        return _failed(str(exc), _elapsed_ms(started))
    except Exception as exc:
        logger.exception("Stage1 internal error")
        return _failed(str(exc), _elapsed_ms(started))

    return DetectorResult(
        name=DETECTOR_NAME,
        detected=result.detected,
        label="INJECTION" if result.detected else "SAFE",
        score=result.score,
        status=DetectorStatus.COMPLETED,
        latency_ms=_elapsed_ms(started),
        attack_type=_ATTACK_TYPE if result.detected else None,
        reason=_reason_for_classification(result, len(chunks)),
        details={
            "model_version": MODEL_VERSION,
            "threshold": result.threshold,
            "chunks_total": len(chunks),
            "chunks_evaluated": result.chunks_evaluated,
            "early_stopped": result.early_stopped,
            "classifier_latency_ms": result.latency_ms,
        },
    )


def _failed(error: str, latency_ms: int) -> DetectorResult:
    return DetectorResult(
        name=DETECTOR_NAME,
        detected=False,
        label="SAFE",
        score=0.0,
        status=DetectorStatus.FAILED,
        latency_ms=latency_ms,
        error=error,
    )


def _reason_for_classification(result: Stage1Classification, chunks_total: int) -> str:
    relation = "met" if result.detected else "was below"
    chunks = f"{result.chunks_evaluated}/{chunks_total} chunks"
    suffix = " with early stop" if result.early_stopped else ""
    return (
        f"Stage1 score {_format_score(result.score)} {relation} threshold "
        f"{_format_score(result.threshold)} across {chunks}{suffix}."
    )


def _format_score(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def _elapsed_ms(started: float) -> int:
    return round((time.perf_counter() - started) * 1000)
