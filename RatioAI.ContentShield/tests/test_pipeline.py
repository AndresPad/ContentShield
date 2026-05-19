"""Tests for the orchestrator detection pipeline."""

from __future__ import annotations

import asyncio

import pytest

from contentshield.domain.errors import InvalidModeError
from contentshield.domain.models import (
    DetectionCommand,
    DetectionMode,
    DetectorResult,
    DetectorStatus,
)
from contentshield.orchestrator.pipeline import run

# -- Helpers --

def _safe(name, score=0.1):
    async def detect(text):
        return DetectorResult(
            name=name, detected=False, label="SAFE",
            score=score, status=DetectorStatus.COMPLETED,
        )
    return detect

def _hit(name, score=0.95):
    async def detect(text):
        return DetectorResult(
            name=name, detected=True, label="INJECTION",
            score=score, status=DetectorStatus.COMPLETED,
        )
    return detect

def _raise(name, msg="kaboom"):
    async def detect(text):
        raise RuntimeError(msg)
    return detect

def _all(**overrides):
    """Default V1 detector set: ACS + Stage2."""
    return {
        "acs_prompt_shield": _safe("acs_prompt_shield"),
        "stage2": _safe("stage2"),
        **overrides,
    }

def _run(text="x", mode=DetectionMode.STANDARD, detectors=None, **kwargs):
    return asyncio.run(run(DetectionCommand(text=text, mode=mode, **kwargs), detectors or _all()))


# -- Standard mode (V1 release) --

class TestNormalMode:

    def test_safe_when_all_clean(self):
        r = _run()
        assert r.verdict == "SAFE"
        assert r.stopped_at_layer == 1
        assert set(r.detectors.keys()) == {"acs_prompt_shield", "stage2"}

    def test_acs_alone_is_advisory_when_stage2_safe(self):
        r = _run(detectors=_all(acs_prompt_shield=_hit("acs_prompt_shield")))
        assert r.verdict == "SAFE"
        assert r.detected is False
        assert r.detectors["acs_prompt_shield"].detected is True
        assert r.detectors["stage2"].detected is False
        assert "Injection detected" not in r.reasons

    def test_injection_when_stage2_hits(self):
        r = _run(detectors=_all(stage2=_hit("stage2")))
        assert r.verdict == "INJECTION"

    def test_injection_when_both_hit(self):
        r = _run(detectors=_all(
            acs_prompt_shield=_hit("acs_prompt_shield"),
            stage2=_hit("stage2"),
        ))
        assert r.verdict == "INJECTION"
        assert r.detectors["acs_prompt_shield"].detected is True
        assert r.detectors["stage2"].detected is True

    def test_standard_mode_runs_acs_and_stage2(self):
        r = _run(mode=DetectionMode.STANDARD, detectors=_all(stage2=_hit("stage2")))
        assert r.verdict == "INJECTION"
        assert set(r.detectors.keys()) == {"acs_prompt_shield", "stage2"}


# -- Unsupported modes --

class TestUnsupportedModes:

    def test_fast_raises(self):
        with pytest.raises(InvalidModeError, match=r"fast.*not available"):
            _run(mode=DetectionMode.FAST)

    def test_raises(self):
        with pytest.raises(InvalidModeError, match=r"deep.*LLM detector"):
            _run(mode=DetectionMode.DEEP)


# -- Failure handling --

class TestFailures:

    def test_exception_preserves_message(self):
        r = _run(detectors=_all(
            acs_prompt_shield=_raise("acs_prompt_shield", "connection refused")
        ))
        assert r.errors["acs_prompt_shield"] == "connection refused"

    def test_all_failed_fails_closed(self):
        # When every attempted detector fails, we have zero signal. The pipeline
        # must NOT silently green-light: fail closed with INJECTION + reason.
        r = _run(detectors={
            "acs_prompt_shield": _raise("acs_prompt_shield"),
            "stage2": _raise("stage2"),
        })
        assert r.verdict == "INJECTION"
        assert r.detected is True
        assert "all_detectors_failed" in r.reasons

    def test_partial_failure_still_detects(self):
        r = _run(detectors=_all(
            acs_prompt_shield=_raise("acs_prompt_shield"),
            stage2=_hit("stage2"),
        ))
        assert r.verdict == "INJECTION"
        assert r.detectors["acs_prompt_shield"].status == DetectorStatus.FAILED


# -- Detector override --

class TestOverride:

    def test_runs_only_named(self):
        r = _run(detector_override=["stage2"])
        assert list(r.detectors.keys()) == ["stage2"] and r.stopped_at_layer == 0

    def test_unknown_marked_failed(self):
        # Unknown override names are caller config errors -- surface as FAILED,
        # not silently SKIPPED.
        r = _run(detector_override=["nonexistent"])
        assert r.detectors["nonexistent"].status == DetectorStatus.FAILED
        assert "not configured" in r.errors["nonexistent"]

    def test_safe_when_override_detector_clean(self):
        r = _run(detector_override=["stage2"])
        assert r.verdict == "SAFE" and r.detected is False

    def test_injection_when_override_detector_hits(self):
        r = _run(
            detector_override=["stage2"],
            detectors=_all(stage2=_hit("stage2")),
        )
        assert r.verdict == "INJECTION" and r.detected is True

    def test_acs_alone_override_uses_or_semantics(self):
        r = _run(
            detector_override=["acs_prompt_shield"],
            detectors=_all(acs_prompt_shield=_hit("acs_prompt_shield")),
        )
        assert r.verdict == "INJECTION"
        assert r.detected is True
        assert r.detectors["acs_prompt_shield"].detected is True

    def test_injection_when_any_override_hits(self):
        r = _run(
            detector_override=["acs_prompt_shield", "stage2"],
            detectors=_all(stage2=_hit("stage2")),
        )
        assert r.verdict == "INJECTION" and r.detected is True
        assert r.detectors["acs_prompt_shield"].detected is False
        assert r.detectors["stage2"].detected is True

    def test_only_unknown_override_fails_closed(self):
        # Override list of only unknown names => all attempted detectors are
        # FAILED => fail-closed INJECTION with all_detectors_failed reason.
        r = _run(detector_override=["nonexistent"])
        assert r.verdict == "INJECTION"
        assert r.detected is True
        assert "all_detectors_failed" in r.reasons


# -- V1 soft-disable contract --

class TestV1SoftDisableContract:
    """Locks the V1 guarantee: stage1 and query_detect are unwired and
    requesting them via override surfaces as FAILED, contributing to the
    fail-closed signal. These run against V1 wiring (ACS + Stage2 only)."""

    def test_stage1_override_returns_failed(self):
        r = _run(detector_override=["stage1"])
        assert r.detectors["stage1"].status == DetectorStatus.FAILED
        assert "not configured" in r.errors["stage1"]
        # Only attempted detector failed => fail-closed.
        assert r.verdict == "INJECTION"
        assert "all_detectors_failed" in r.reasons

    def test_query_detect_option_is_noop(self):
        # In V1, enable_query_detection has no effect: query_detect is not
        # wired into the default detector set, so it never appears in the
        # response regardless of the option.
        r = _run(enable_query_detection=True)
        assert "query_detect" not in r.detectors
        assert set(r.detectors.keys()) == {"acs_prompt_shield", "stage2"}
