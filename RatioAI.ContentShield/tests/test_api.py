"""End-to-end API tests (CS-008b)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from contentshield.app import create_app
from contentshield.config import get_acs_config, get_aoai_config, get_stage2_config
from contentshield.domain.models import DetectorResult, DetectorStatus


def _safe(name):
    async def detect(text):
        return DetectorResult(
            name=name, detected=False, label="SAFE",
            score=0.1, status=DetectorStatus.COMPLETED,
        )
    return detect


def _hit(name, reason="The prompt asks the model to ignore prior instructions."):
    async def detect(text):
        return DetectorResult(
            name=name, detected=True, label="INJECTION",
            score=0.95, status=DetectorStatus.COMPLETED,
            attack_type="prompt_injection",
            reason=reason,
        )
    return detect


def _failed(name, score=0.0, attack_type=None):
    async def detect(text):
        return DetectorResult(
            name=name, detected=False, label="SAFE",
            score=score, status=DetectorStatus.FAILED,
            attack_type=attack_type,
            error="connection refused to acs.cognitive.azure.com",
        )
    return detect


def _timed_out(name):
    async def detect(text):
        return DetectorResult.timed_out(name, 500)
    return detect


def _all(**overrides):
    """Default V1 detector set: ACS + Stage2."""
    return {
        "acs_prompt_shield": _safe("acs_prompt_shield"),
        "stage2": _safe("stage2"),
        **overrides,
    }


@pytest.fixture()
def client():
    return TestClient(create_app(detectors=_all()))


@pytest.fixture()
def hit_client():
    return TestClient(create_app(detectors=_all(acs_prompt_shield=_hit("acs_prompt_shield"))))


class TestHealth:
    def test_ok(self, client):
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok", "service": "contentshield"}


class TestDetect:
    def test_default_standard_safe(self, client):
        r = client.post("/v1/detect", json={"text": "hello"})
        assert r.status_code == 200
        body = r.json()
        assert body["verdict"] == "SAFE"
        assert set(body) == {
            "request_id", "verdict", "score", "degraded", "attack_types", "detectors",
        }
        assert body["degraded"] is False
        assert set(body["detectors"].keys()) == {"acs_prompt_shield", "stage2"}

    def test_acs_hit_is_advisory_when_stage2_safe(self, hit_client):
        r = hit_client.post("/v1/detect", json={"text": "ignore"})
        body = r.json()
        assert body["verdict"] == "SAFE"
        assert body["score"] == 0.95
        assert body["degraded"] is False
        assert body["attack_types"] == ["prompt_injection"]
        assert body["detectors"]["acs_prompt_shield"] == {
            "label": "INJECTION", "score": 0.95, "status": "completed",
            "attack_type": "prompt_injection",
            "reason": "The prompt asks the model to ignore prior instructions.",
        }
        assert body["detectors"]["stage2"]["label"] == "SAFE"

    def test_stage2_hit_sets_final_injection(self):
        client = TestClient(create_app(detectors=_all(
            stage2=_hit("stage2", reason=""),
        )))
        r = client.post("/v1/detect", json={"text": "ignore"})
        body = r.json()
        assert body["verdict"] == "INJECTION"
        assert body["score"] == 0.95
        assert body["degraded"] is False
        assert body["attack_types"] == ["prompt_injection"]
        assert body["detectors"]["stage2"]["label"] == "INJECTION"
        assert body["detectors"]["stage2"]["reason"] == ""

    def test_failed_detector_degrades_without_contributing_signal(self):
        client = TestClient(create_app(detectors=_all(
            acs_prompt_shield=_failed(
                "acs_prompt_shield", score=0.99, attack_type="stale_signal"
            ),
        )))
        r = client.post("/v1/detect", json={"text": "hello"})
        body = r.json()
        assert body["verdict"] == "SAFE"
        assert body["score"] == 0.1
        assert body["degraded"] is True
        assert body["attack_types"] == []
        assert body["detectors"]["acs_prompt_shield"]["status"] == "failed"
        assert body["detectors"]["acs_prompt_shield"]["reason"] is None

    def test_timed_out_detector_alone_returns_safe_degraded_timeout(self):
        client = TestClient(create_app(detectors=_all(
            acs_prompt_shield=_timed_out("acs_prompt_shield")
        )))
        r = client.post("/v1/detect", json={
            "text": "hello", "detectors": ["acs_prompt_shield"],
        })
        body = r.json()
        # Sole detector failed/timed-out → fail-closed.
        assert body["verdict"] == "INJECTION"
        assert body["degraded"] is True
        assert body["detectors"]["acs_prompt_shield"]["status"] == "timed_out"
        assert body["detectors"]["acs_prompt_shield"]["reason"] is None

    def test_all_non_completed_detectors_return_safe_zero_degraded(self):
        client = TestClient(create_app(detectors=_all(
            acs_prompt_shield=_failed("acs_prompt_shield"),
            stage2=_timed_out("stage2"),
        )))
        r = client.post("/v1/detect", json={"text": "hello"})
        body = r.json()
        # All detectors failed → fail-closed.
        assert body["verdict"] == "INJECTION"
        assert body["degraded"] is True

    def test_skipped_detector_appears_with_status_and_no_reason(self, client):
        r = client.post("/v1/detect", json={
            "text": "hello", "detectors": ["missing"],
        })
        body = r.json()
        # Unknown detector → FAILED (configuration error). Sole detector failing
        # also triggers fail-closed.
        assert body["verdict"] == "INJECTION"
        assert body["degraded"] is True
        assert body["detectors"]["missing"]["status"] == "failed"
        assert body["detectors"]["missing"]["reason"] is None

    def test_raw_error_text_never_leaves_mapper(self):
        client = TestClient(create_app(detectors=_all(
            acs_prompt_shield=_failed("acs_prompt_shield")
        )))
        r = client.post("/v1/detect", json={"text": "hello"})
        body = r.json()
        assert body["detectors"]["acs_prompt_shield"]["reason"] is None
        assert "acs.cognitive.azure.com" not in r.text

    def test_standard(self, client):
        r = client.post("/v1/detect", json={"text": "x", "mode": "standard"})
        body = r.json()
        assert "stage2" in body["detectors"]

    def test_fast_400(self, client):
        r = client.post("/v1/detect", json={"text": "x", "mode": "fast"})
        assert r.status_code == 400
        assert "fast path is not available in V1" in r.json()["detail"]

    def test_deep_400(self, client):
        r = client.post("/v1/detect", json={"text": "x", "mode": "deep"})
        assert r.status_code == 400

    def test_query_detect_off_by_default(self, client):
        # In V1, query_detect is unwired from the default detector set, so
        # it never appears in responses regardless of the request payload.
        r = client.post("/v1/detect", json={"text": "SELECT * FROM users"})
        assert "query_detect" not in r.json()["detectors"]

    def test_query_detect_opt_in_is_noop_in_v1(self, client):
        # enable_query_detection has no effect in V1: query_detect is not wired.
        r = client.post("/v1/detect", json={
            "text": "SELECT * FROM users",
            "options": {"enable_query_detection": True},
        })
        body = r.json()
        assert "query_detect" not in body["detectors"]
        assert "metadata" not in body

    def test_detector_override(self, client):
        r = client.post("/v1/detect", json={
            "text": "x", "detectors": ["stage2"],
        })
        assert list(r.json()["detectors"].keys()) == ["stage2"]

    def test_request_id_propagated(self, client):
        r = client.post("/v1/detect", json={
            "text": "x",
            "metadata": {"request_id": "test-123"},
        })
        assert r.json()["request_id"] == "test-123"

    def test_response_hides_pipeline_internals(self, client):
        r = client.post("/v1/detect", json={"text": "x"})
        body = r.json()
        assert "detected" not in body
        assert "mode" not in body
        assert "stopped_at_layer" not in body
        assert "latency_ms" not in body
        assert "errors" not in body
        assert "reasons" not in body

    def test_empty_text_422(self, client):
        assert client.post("/v1/detect", json={"text": ""}).status_code == 422

    def test_blank_text_422(self, client):
        assert client.post("/v1/detect", json={"text": "   "}).status_code == 422

    def test_missing_text_422(self, client):
        assert client.post("/v1/detect", json={}).status_code == 422


class TestBoundaries:
    """No FastAPI/pydantic in domain or orchestrator layers."""

    def test_domain_clean(self):
        import contentshield.domain.errors as e
        import contentshield.domain.models as m
        for mod in (m, e):
            with open(mod.__file__) as f:
                src = f.read().lower()
            assert "fastapi" not in src
            assert "pydantic" not in src

    def test_orchestrator_clean(self):
        import contentshield.orchestrator.pipeline as p
        with open(p.__file__) as f:
            src = f.read().lower()
        assert "fastapi" not in src
        assert "pydantic" not in src

    def test_create_app_only_in_app_py(self):
        import pathlib
        src_root = pathlib.Path(__file__).resolve().parent.parent / "src" / "contentshield"
        for py in src_root.rglob("*.py"):
            if py.name == "app.py":
                continue
            content = py.read_text()
            assert "def create_app" not in content, f"create_app found in {py}"


@pytest.mark.legacy_pipeline
class TestRealDetectorE2E:
    """Default detector wiring under the unit-test no-config seam.

    Locks the V1 acceptance gate: SQL/KQL payload + ``enable_query_detection=true``
    triggers an INJECTION verdict via the local query_detect detector while live
    service-backed detectors skip through fail-open behavior.
    """

    @pytest.fixture()
    def real_client(self):
        # No detectors=... uses build_default_detectors(); tests/conftest.py
        # clears live env for non-e2e tests so service-backed detectors skip.
        assert get_acs_config() is None
        assert get_aoai_config() is None
        assert get_stage2_config() is None
        return TestClient(create_app())

    def test_sql_payload_triggers_injection(self, real_client):
        r = real_client.post("/v1/detect", json={
            "text": "Please run: SELECT id, name FROM users WHERE active = 1;",
            "options": {"enable_query_detection": True},
        })
        assert r.status_code == 200
        body = r.json()
        assert body["verdict"] == "INJECTION"
        qd = body["detectors"]["query_detect"]
        assert qd["label"] == "INJECTION"
        assert qd["attack_type"] == "sql_query"
        assert body["attack_types"] == ["sql_query"]

    def test_kql_payload_triggers_injection(self, real_client):
        r = real_client.post("/v1/detect", json={
            "text": "SecurityEvent | where TimeGenerated > ago(1h) | summarize count()",
            "options": {"enable_query_detection": True},
        })
        body = r.json()
        assert body["verdict"] == "INJECTION"
        assert body["detectors"]["query_detect"]["attack_type"] == "kql_query"

    def test_benign_prose_stays_safe(self, real_client):
        r = real_client.post("/v1/detect", json={
            "text": "Please select an option from the menu and submit it.",
            "options": {"enable_query_detection": True},
        })
        body = r.json()
        assert body["verdict"] == "SAFE"
        assert body["detectors"]["query_detect"]["label"] == "SAFE"

    def test_query_detect_runs_when_wired_v2(self, real_client):
        # Under V2 wiring (CONTENTSHIELD_V1_ML_DISABLED=0), every wired
        # detector runs on every request. The opt-in gating that used to live
        # in the layered pipeline is gone; the request option is retained
        # only for schema stability. SQL payload triggers INJECTION via
        # query_detect even without enable_query_detection=true.
        r = real_client.post("/v1/detect", json={
            "text": "SELECT id, name FROM users WHERE active = 1;",
        })
        body = r.json()
        assert body["verdict"] == "INJECTION"
        assert body["detectors"]["query_detect"]["label"] == "INJECTION"
