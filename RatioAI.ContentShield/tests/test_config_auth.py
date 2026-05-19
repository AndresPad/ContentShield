from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import TYPE_CHECKING

from contentshield import auth
from contentshield.config import get_acs_config, get_aoai_config, get_stage2_config

if TYPE_CHECKING:
    import pytest


def test_blank_endpoints_return_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONTENT_SAFETY_ENDPOINT", "   ")
    monkeypatch.setenv("STAGE1_AOAI_ENDPOINT", "")
    monkeypatch.setenv("SLM_ENDPOINT", "   ")

    assert get_acs_config() is None
    assert get_aoai_config() is None
    assert get_stage2_config() is None


def test_endpoint_values_trim_trailing_slashes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONTENT_SAFETY_ENDPOINT", "https://acs.example.com///")
    monkeypatch.setenv("STAGE1_AOAI_ENDPOINT", "https://aoai.example.com/")
    monkeypatch.setenv("SLM_ENDPOINT", "https://stage2.example.com//")

    acs_config = get_acs_config()
    aoai_config = get_aoai_config()
    stage2_config = get_stage2_config()

    assert acs_config is not None
    assert aoai_config is not None
    assert stage2_config is not None
    assert acs_config.endpoint == "https://acs.example.com"
    assert aoai_config.endpoint == "https://aoai.example.com"
    assert stage2_config.endpoint == "https://stage2.example.com"
    assert stage2_config.path == "/v1/chat/completions"
    assert stage2_config.model == "google/gemma-4-31b-it"


def test_stage2_path_can_be_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SLM_ENDPOINT", "https://stage2.example.com")
    monkeypatch.setenv("SLM_PATH", "classify/")

    stage2_config = get_stage2_config()

    assert stage2_config is not None
    assert stage2_config.endpoint == "https://stage2.example.com"
    assert stage2_config.path == "/classify"


def test_stage2_path_can_be_inferred_from_endpoint(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SLM_ENDPOINT", "https://stage2.example.com/classify")

    stage2_config = get_stage2_config()

    assert stage2_config is not None
    assert stage2_config.endpoint == "https://stage2.example.com"
    assert stage2_config.path == "/classify"


def test_cognitive_services_headers_prefers_api_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingCredential:
        async def get_token(self, scope: str) -> None:
            raise AssertionError("DefaultAzureCredential should not be used")

    monkeypatch.setattr(auth, "DEFAULT_AZURE_CREDENTIAL", FailingCredential())

    headers = asyncio.run(auth.cognitive_services_headers("test-key"))

    assert headers == {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": "test-key",
    }


def test_cognitive_services_headers_uses_bearer_token_when_key_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token_calls: list[str] = []

    class FakeCredential:
        async def get_token(self, scope: str) -> SimpleNamespace:
            token_calls.append(scope)
            return SimpleNamespace(token="mock-token")

    monkeypatch.setattr(auth, "DEFAULT_AZURE_CREDENTIAL", FakeCredential())

    headers = asyncio.run(auth.cognitive_services_headers(None))

    assert token_calls == [auth.COGNITIVE_SERVICES_SCOPE]
    assert headers == {
        "Content-Type": "application/json",
        "Authorization": "Bearer mock-token",
    }
