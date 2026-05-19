"""SHA-verified sklearn classifier for the Stage-1 residual detector."""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import joblib
import numpy as np

from contentshield.config import get_stage1_config

EMBEDDING_DIM = 1536
MODEL_VERSION = "stage1_logreg_v1"
MODEL_DIR = Path(__file__).resolve().parent / "models"
MODEL_PATH = MODEL_DIR / "stage1_logreg.joblib"
SHA256_PATH = MODEL_DIR / "stage1_logreg.sha256"


class InvalidClassifierInputError(Exception):
    """Raised when the classifier receives an invalid embedding matrix."""


@dataclass(frozen=True)
class Stage1Classification:
    """Stage-1 classifier output."""

    detected: bool
    score: float
    threshold: float
    chunks_evaluated: int
    early_stopped: bool
    latency_ms: int


def classify(chunk_embeddings: np.ndarray) -> Stage1Classification:
    """Score chunk embeddings with max-pooling and early stop."""
    matrix = _validate_embeddings(chunk_embeddings)
    cfg = get_stage1_config()
    decision_threshold = (
        cfg.decision_threshold
        if cfg.decision_threshold is not None
        else MODEL_DEFAULT_THRESHOLD
    )
    early_stop_threshold = cfg.early_stop_threshold

    started = time.perf_counter()
    max_score = 0.0
    chunks_evaluated = 0
    early_stopped = False

    for embedding in matrix:
        probability = float(_PIPELINE.predict_proba(embedding.reshape(1, -1))[0, 1])
        chunks_evaluated += 1
        max_score = max(max_score, probability)
        if probability >= early_stop_threshold:
            early_stopped = True
            break

    rounded_score = round(max_score, 6)
    return Stage1Classification(
        detected=rounded_score >= decision_threshold,
        score=rounded_score,
        threshold=decision_threshold,
        chunks_evaluated=chunks_evaluated,
        early_stopped=early_stopped,
        latency_ms=round((time.perf_counter() - started) * 1000),
    )


def _load_model() -> tuple[Any, float]:
    expected_sha = _expected_sha256()
    actual_sha = hashlib.sha256(MODEL_PATH.read_bytes()).hexdigest()
    if actual_sha != expected_sha:
        raise RuntimeError(
            "Stage-1 model checksum mismatch. "
            f"Expected {expected_sha}, got {actual_sha}."
        )

    artifact = joblib.load(MODEL_PATH)
    if isinstance(artifact, dict):
        pipeline = artifact["pipeline"]
        threshold = float(artifact.get("threshold", 0.5))
    else:
        pipeline = artifact
        threshold = 0.5
    return pipeline, threshold


def _expected_sha256() -> str:
    expected_sha = SHA256_PATH.read_text(encoding="utf-8").strip().lower()
    if not expected_sha:
        raise RuntimeError("Stage-1 model checksum file is empty")
    return expected_sha


def _validate_embeddings(chunk_embeddings: np.ndarray) -> np.ndarray:
    matrix = np.asarray(chunk_embeddings, dtype=np.float32)
    if matrix.ndim != 2 or matrix.shape[1] != EMBEDDING_DIM:
        raise InvalidClassifierInputError(
            f"Stage-1 embedding matrix shape {matrix.shape} is invalid"
        )
    if matrix.shape[0] == 0:
        raise InvalidClassifierInputError("Stage-1 embedding matrix is empty")
    return matrix


_PIPELINE, MODEL_DEFAULT_THRESHOLD = _load_model()
# Backwards-compatible alias: the joblib's trained threshold is the default.
DECISION_THRESHOLD = MODEL_DEFAULT_THRESHOLD
