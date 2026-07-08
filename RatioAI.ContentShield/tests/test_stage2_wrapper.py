from __future__ import annotations

import importlib.util
import sys
import types
import uuid
from pathlib import Path

import pytest

_STAGE2_MAIN = (
    Path(__file__).resolve().parents[1]
    / "services"
    / "stage2"
    / "src"
    / "stage2"
    / "main.py"
)


def _load_stage2_main(monkeypatch: pytest.MonkeyPatch, **env: str):
    fake_openai = types.ModuleType("openai")
    fake_openai.AsyncOpenAI = object
    monkeypatch.setitem(sys.modules, "openai", fake_openai)

    for name in (
        "ENABLE_STAGE2_REASON",
        "MAX_REASON_TOKENS",
        "VLLM_URL",
        "VLLM_HEALTH_URL",
    ):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)

    module_name = f"stage2_main_test_{uuid.uuid4().hex}"
    spec = importlib.util.spec_from_file_location(module_name, _STAGE2_MAIN)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_invalid_max_reason_tokens_is_ignored_when_reason_disabled(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        ENABLE_STAGE2_REASON="false",
        MAX_REASON_TOKENS="not-an-int",
    )

    assert module.ENABLE_STAGE2_REASON is False
    assert module.MAX_REASON_TOKENS == 256


def test_stage2_reason_defaults_enabled_with_256_token_budget(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(monkeypatch)

    assert module.ENABLE_STAGE2_REASON is True
    assert module.MAX_REASON_TOKENS == 256


def test_vllm_health_url_defaults_to_vllm_url_health(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        VLLM_URL="http://127.0.0.1:8000/",
    )

    assert module.VLLM_URL == "http://127.0.0.1:8000"
    assert module.VLLM_HEALTH_URL == "http://127.0.0.1:8000/health"


def test_vllm_health_url_can_be_configured_separately(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        VLLM_URL="http://127.0.0.1:8000",
        VLLM_HEALTH_URL="http://127.0.0.1:9000/health/",
    )

    assert module.VLLM_URL == "http://127.0.0.1:8000"
    assert module.VLLM_HEALTH_URL == "http://127.0.0.1:9000/health"


def test_invalid_max_reason_tokens_fails_when_reason_enabled(
    monkeypatch: pytest.MonkeyPatch,
):
    with pytest.raises(RuntimeError, match="Invalid MAX_REASON_TOKENS"):
        _load_stage2_main(
            monkeypatch,
            ENABLE_STAGE2_REASON="true",
            MAX_REASON_TOKENS="not-an-int",
        )


def test_clean_reason_sentence_boundary_at_limit_never_exceeds_response_limit(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(monkeypatch)
    content = f"{'a' * 200}. This sentence should be removed."

    reason = module._clean_reason(content)

    assert len(reason) == 200
    assert reason.endswith("...")


def test_clean_reason_sentence_boundary_inside_limit_keeps_sentence(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(monkeypatch)
    content = f"{'a' * 199}. This sentence should be removed."

    reason = module._clean_reason(content)

    assert len(reason) == 200
    assert reason == f"{'a' * 199}."
