from __future__ import annotations

import asyncio
import importlib
import sys
from pathlib import Path
from types import ModuleType

PROJECT_ROOT = Path(__file__).resolve().parents[1]


class _FakeResponse:
    def __init__(self, payload: dict):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


class _FakeClient:
    def __init__(self, payload: dict):
        self.payload = payload
        self.posts: list[tuple[str, dict, dict]] = []

    async def post(self, url: str, **kwargs) -> _FakeResponse:
        self.posts.append((url, kwargs.get("json", {}), kwargs.get("headers", {})))
        return _FakeResponse(self.payload)


def _metric_not_used(*_args, **_kwargs):
    raise AssertionError("metric dependency should not be called by adapter caller tests")


def _install_eval_runner_import_stubs(monkeypatch) -> None:
    matplotlib = ModuleType("matplotlib")
    matplotlib.__path__ = []
    matplotlib.use = lambda *_args, **_kwargs: None
    pyplot = ModuleType("matplotlib.pyplot")
    matplotlib.pyplot = pyplot

    sklearn = ModuleType("sklearn")
    sklearn.__path__ = []
    metrics = ModuleType("sklearn.metrics")
    for name in (
        "accuracy_score",
        "classification_report",
        "confusion_matrix",
        "f1_score",
        "precision_recall_curve",
        "precision_score",
        "recall_score",
        "roc_auc_score",
        "roc_curve",
    ):
        setattr(metrics, name, _metric_not_used)
    sklearn.metrics = metrics

    for name, module in {
        "matplotlib": matplotlib,
        "matplotlib.pyplot": pyplot,
        "mlflow": ModuleType("mlflow"),
        "numpy": ModuleType("numpy"),
        "pandas": ModuleType("pandas"),
        "sklearn": sklearn,
        "sklearn.metrics": metrics,
        "tyro": ModuleType("tyro"),
    }.items():
        monkeypatch.setitem(sys.modules, name, module)


def _import_runner(module_name: str, monkeypatch):
    _install_eval_runner_import_stubs(monkeypatch)
    monkeypatch.syspath_prepend(str(PROJECT_ROOT))
    sys.modules.pop(module_name, None)
    return importlib.import_module(module_name)


def test_run_eval_stage1_preserves_detector_degradation_fields(monkeypatch):
    run_eval = _import_runner("evals.run_eval", monkeypatch)
    monkeypatch.setattr(run_eval._token_holder, "get", lambda: "test-token")
    client = _FakeClient({
        "request_id": "req-stage1",
        "verdict": "SAFE",
        "score": 0.12,
        "degraded": True,
        "attack_types": [],
        "detectors": {
            "acs_prompt_shield": {
                "detected": False,
                "label": "SAFE",
                "score": 0.0,
                "status": "failed",
                "reason": None,
            },
            "stage1": {
                "detected": False,
                "label": "SAFE",
                "score": 0.0,
                "status": "timed_out",
                "reason": None,
            },
            "stage2": {
                "detected": False,
                "label": "SAFE",
                "score": 0.0,
                "status": "skipped",
                "reason": None,
            },
        },
    })

    result = asyncio.run(run_eval.classify_one_stage1(
        client,
        "https://orchestrator.example",
        {"id": "sample-1", "text": "hello", "expected_label": "OK"},
        asyncio.Semaphore(1),
    ))

    assert result["predicted_label"] == "OK"
    assert result["raw_output"] == "SAFE"
    assert result["score"] == 0.12
    assert result["degraded"] is True
    assert result["detector_status_counts"] == {"failed": 1, "timed_out": 1, "skipped": 1}
    assert result["incomplete_detectors"] == ["acs_prompt_shield", "stage1", "stage2"]
    assert result["detector_reasons"] == {
        "acs_prompt_shield": None,
        "stage1": None,
        "stage2": None,
    }
    assert client.posts[0][0] == "https://orchestrator.example/v1/detect"


def test_run_pipeline_process_sample_preserves_detector_evidence_fields(monkeypatch):
    run_pipeline_eval = _import_runner("evals.run_pipeline_eval", monkeypatch)

    async def fake_call_orchestrator(_client, _orch_url, _text, _config_kwargs, _sem):
        return {
            "ok": True,
            "latency_ms": 44.4,
            "data": {
                "request_id": "req-pipeline",
                "verdict": "SAFE",
                "score": 0.2,
                "degraded": True,
                "attack_types": [],
                "latency_ms": {"end_to_end": 33.3},
                "reasons": ["fallback path"],
                "detectors": {
                    "acs_prompt_shield": {
                        "detected": False,
                        "label": "SAFE",
                        "score": 0.0,
                        "status": "failed",
                        "reason": None,
                        "latency_ms": 10.0,
                    },
                    "stage1": {
                        "detected": False,
                        "label": "SAFE",
                        "score": 0.0,
                        "status": "timed_out",
                        "reason": None,
                    },
                    "query_detect": {
                        "detected": False,
                        "label": "SAFE",
                        "score": 0.0,
                        "status": "skipped",
                        "reason": None,
                    },
                },
            },
        }

    monkeypatch.setattr(run_pipeline_eval, "call_orchestrator", fake_call_orchestrator)

    result = asyncio.run(run_pipeline_eval._process_sample(
        client=object(),
        orch_url="https://orchestrator.example",
        sample={"id": "sample-3", "text": "hello", "expected_label": "OK"},
        config_kwargs={"mode": "standard"},
        sem=asyncio.Semaphore(1),
    ))

    assert result["predicted_label"] == "OK"
    assert result["score"] == 0.2
    assert result["degraded"] is True
    assert result["detector_status_counts"] == {"failed": 1, "timed_out": 1, "skipped": 1}
    assert result["incomplete_detectors"] == [
        "acs_prompt_shield",
        "stage1",
        "query_detect",
    ]
    assert result["detector_reasons"] == {
        "acs_prompt_shield": None,
        "stage1": None,
        "query_detect": None,
    }
    assert result["detectors"]["acs_prompt_shield"]["status"] == "failed"
    assert result["detectors"]["acs_prompt_shield"]["reason"] is None
    assert result["detectors"]["stage1"]["status"] == "timed_out"
    assert result["detectors"]["stage1"]["reason"] is None
    assert result["detectors"]["query_detect"]["status"] == "skipped"
    assert result["detectors"]["query_detect"]["reason"] is None
    assert result["reasons"] == ["fallback path"]
    assert result["latency_ms"] == 33.3
    assert result["client_latency_ms"] == 44.4
