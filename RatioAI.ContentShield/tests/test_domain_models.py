"""Tests for orchestrator domain models."""

from __future__ import annotations

import pytest

from contentshield.domain.models import DetectorResult, DetectorStatus


class TestDetectorResultFactories:

    def test_failed(self):
        r = DetectorResult.failed("d", "boom", 42)
        assert (r.status, r.error, r.latency_ms, r.detected) == (
            DetectorStatus.FAILED, "boom", 42, False,
        )

    def test_timed_out(self):
        r = DetectorResult.timed_out("d", 500)
        assert (r.status, r.latency_ms) == (DetectorStatus.TIMED_OUT, 500)

    def test_skipped(self):
        r = DetectorResult.skipped("d")
        assert (r.status, r.score) == (DetectorStatus.SKIPPED, 0.0)


class TestDetectorResultValidation:

    @pytest.mark.parametrize("bad_score", [-0.1, 1.1, 2.0])
    def test_score_out_of_bounds(self, bad_score):
        with pytest.raises(ValueError, match="score must be"):
            DetectorResult(
                name="x", detected=False, label="SAFE",
                score=bad_score, status=DetectorStatus.COMPLETED,
            )

    def test_frozen(self):
        r = DetectorResult.failed("d", "err")
        with pytest.raises(AttributeError):
            r.score = 0.5  # type: ignore[misc]

    def test_details(self):
        r = DetectorResult(
            name="qd", detected=True, label="INJECTION", score=0.8,
            status=DetectorStatus.COMPLETED,
            details={"language": "sql"},
        )
        assert r.details["language"] == "sql"
