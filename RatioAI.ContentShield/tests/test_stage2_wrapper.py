from __future__ import annotations

import importlib.util
import sys
import types
import uuid
from pathlib import Path

import httpx
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
    class FakeAPIError(Exception):
        pass

    class FakeBadRequestError(FakeAPIError):
        def __init__(self, response: httpx.Response):
            super().__init__("bad request")
            self.response = response

    class FakeAsyncAzureOpenAI:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        async def close(self):
            pass

    fake_openai = types.ModuleType("openai")
    fake_openai.AsyncOpenAI = object
    fake_openai.AsyncAzureOpenAI = FakeAsyncAzureOpenAI
    fake_openai.APIError = FakeAPIError
    fake_openai.APIConnectionError = FakeAPIError
    fake_openai.APITimeoutError = FakeAPIError
    fake_openai.BadRequestError = FakeBadRequestError
    monkeypatch.setitem(sys.modules, "openai", fake_openai)

    for name in (
        "ENABLE_STAGE2_REASON",
        "MAX_REASON_TOKENS",
        "STAGE2_BACKEND",
        "VLLM_URL",
        "VLLM_HEALTH_URL",
        "AZURE_OPENAI_ENDPOINT",
        "AZURE_OPENAI_DEPLOYMENT",
        "AZURE_OPENAI_API_KEY",
        "AZURE_OPENAI_BEARER_TOKEN",
        "AZURE_OPENAI_MAX_RETRIES",
        "AZURE_OPENAI_TOP_LOGPROBS",
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
    module._fake_openai = fake_openai
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


def test_invalid_stage2_backend_fails_at_startup(monkeypatch: pytest.MonkeyPatch):
    with pytest.raises(RuntimeError, match="Invalid STAGE2_BACKEND"):
        _load_stage2_main(monkeypatch, STAGE2_BACKEND="unsupported")


def test_azure_openai_top_logprobs_defaults_to_ten(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test",
    )

    assert module.AZURE_OPENAI_TOP_LOGPROBS == 10
    assert module.AZURE_OPENAI_MAX_RETRIES == 1
    assert module.AZURE_OPENAI_TIMEOUT_S == 3


def test_vllm_logprobs_require_both_yes_and_no_candidates(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(monkeypatch)
    choice = types.SimpleNamespace(
        logprobs=types.SimpleNamespace(
            content=[
                types.SimpleNamespace(
                    token="YES",
                    logprob=-0.1,
                    top_logprobs=[types.SimpleNamespace(token="YES", logprob=-0.1)],
                )
            ]
        )
    )

    with pytest.raises(module._LogprobError, match="missing YES or NO"):
        module._extract_yes_no_logprobs(choice)


@pytest.mark.asyncio
async def test_vllm_classify_falls_back_to_candidate_prompt_logprobs(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        ENABLE_STAGE2_REASON="false",
    )
    candidate_prompts: list[list[int]] = []

    async def create_chat_completion(**kwargs):
        return types.SimpleNamespace(
            choices=[
                types.SimpleNamespace(
                    message=types.SimpleNamespace(content="YES"),
                    logprobs=types.SimpleNamespace(
                        content=[
                            types.SimpleNamespace(
                                token="YES",
                                logprob=-0.1,
                                top_logprobs=[
                                    types.SimpleNamespace(token="YES", logprob=-0.1)
                                ],
                            )
                        ]
                    )
                )
            ]
        )

    async def create_completion(**kwargs):
        prompt = kwargs["prompt"]
        candidate_prompts.append(prompt)
        candidate = "YES" if prompt[-1] == 1 else "NO"
        logprob = -0.05 if candidate == "YES" else -3.0
        return types.SimpleNamespace(
            choices=[
                types.SimpleNamespace(
                    prompt_logprobs=[
                        None,
                        {0: {"decoded_token": candidate, "logprob": logprob}},
                    ]
                )
            ]
        )

    async def render_chat_token_ids(text: str, system_prompt: str):
        assert text == "candidate text"
        assert system_prompt == "Classify this text."
        return [100, 200]

    monkeypatch.setattr(module, "_render_chat_token_ids", render_chat_token_ids)
    module._state["client"] = types.SimpleNamespace(
        chat=types.SimpleNamespace(
            completions=types.SimpleNamespace(create=create_chat_completion)
        ),
        completions=types.SimpleNamespace(create=create_completion),
    )
    module._state["system_prompt"] = "Classify this text."
    module._state["vllm_candidate_token_ids"] = {"YES": 1, "NO": 2}

    result = await module.classify(module.ClassifyRequest(text="candidate text"))

    assert result.injection is True
    assert result.label == "YES"
    assert result.score == pytest.approx(0.950263, rel=1e-5)
    assert len(candidate_prompts) == 2
    assert [100, 200, 1] in candidate_prompts
    assert [100, 200, 2] in candidate_prompts


@pytest.mark.asyncio
async def test_vllm_generated_label_remains_authoritative_over_fallback_score(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        ENABLE_STAGE2_REASON="false",
    )

    async def create_chat_completion(**kwargs):
        return types.SimpleNamespace(
            choices=[
                types.SimpleNamespace(
                    message=types.SimpleNamespace(content="NO"),
                    logprobs=types.SimpleNamespace(
                        content=[
                            types.SimpleNamespace(
                                token="NO",
                                logprob=-0.1,
                                top_logprobs=[
                                    types.SimpleNamespace(token="NO", logprob=-0.1)
                                ],
                            )
                        ]
                    ),
                )
            ]
        )

    async def score_with_prompt_logprobs(text, client, system_prompt):
        return 0.9

    monkeypatch.setattr(
        module,
        "_score_with_prompt_logprobs",
        score_with_prompt_logprobs,
    )
    module._state["client"] = types.SimpleNamespace(
        chat=types.SimpleNamespace(
            completions=types.SimpleNamespace(create=create_chat_completion)
        )
    )
    module._state["system_prompt"] = "Classify this text."

    result = await module.classify(module.ClassifyRequest(text="candidate text"))

    assert result.injection is False
    assert result.label == "NO"
    assert result.score == 0.9


@pytest.mark.asyncio
async def test_azure_openai_client_uses_sdk_routing_and_bearer_token(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test/",
        AZURE_OPENAI_DEPLOYMENT="gpt-4o-test",
        AZURE_OPENAI_BEARER_TOKEN="test-token",
    )

    client = await module._create_azure_openai_client()

    assert client.kwargs == {
        "azure_endpoint": "https://aoai.example.test",
        "azure_deployment": "gpt-4o-test",
        "api_version": "2024-10-21",
        "timeout": 3.0,
        "max_retries": 1,
        "azure_ad_token": "test-token",
    }


@pytest.mark.asyncio
async def test_azure_openai_client_warms_and_refreshes_managed_identity(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test",
    )
    requested_scopes: list[str] = []

    class FakeCredential:
        async def get_token(self, scope: str):
            requested_scopes.append(scope)
            return types.SimpleNamespace(token="managed-identity-token")

        async def close(self):
            pass

    azure_module = types.ModuleType("azure")
    identity_module = types.ModuleType("azure.identity")
    identity_aio_module = types.ModuleType("azure.identity.aio")
    identity_aio_module.DefaultAzureCredential = FakeCredential
    monkeypatch.setitem(sys.modules, "azure", azure_module)
    monkeypatch.setitem(sys.modules, "azure.identity", identity_module)
    monkeypatch.setitem(sys.modules, "azure.identity.aio", identity_aio_module)

    client = await module._create_azure_openai_client()
    token_provider = client.kwargs["azure_ad_token_provider"]

    assert await token_provider() == "managed-identity-token"
    assert requested_scopes == [module.AZURE_OPENAI_SCOPE] * 2


@pytest.mark.asyncio
async def test_azure_openai_backend_uses_constrained_output_and_logprobs(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test/",
        AZURE_OPENAI_DEPLOYMENT="gpt-4o",
        AZURE_OPENAI_API_KEY="test-key",
        AZURE_OPENAI_TOP_LOGPROBS="10",
    )
    captured: dict[str, object] = {}
    body = {
        "choices": [
            {
                "message": {"content": '{"answer":"YES"}'},
                "logprobs": {
                    "content": [
                        {"token": "{", "logprob": 0.0, "top_logprobs": []},
                        {
                            "token": "YES",
                            "logprob": -0.05,
                            "top_logprobs": [
                                {"token": "YES", "logprob": -0.05},
                                {"token": "NO", "logprob": -3.0},
                            ],
                        },
                    ]
                },
            }
        ]
    }

    async def create_completion(**kwargs):
        captured.update(kwargs)
        return types.SimpleNamespace(model_dump=lambda: body)

    client = types.SimpleNamespace(
        chat=types.SimpleNamespace(
            completions=types.SimpleNamespace(create=create_completion)
        )
    )
    module._state["client"] = client
    module._state["system_prompt"] = "Classify this text."
    result = await module._classify_azure_openai("candidate text")

    assert result.injection is True
    assert result.label == "YES"
    assert result.score == pytest.approx(0.950263, rel=1e-5)
    assert captured["model"] == "gpt-4o"
    assert captured["top_logprobs"] == 10
    assert captured["response_format"]["json_schema"]["schema"]["properties"][
        "answer"
    ]["enum"] == ["YES", "NO"]


@pytest.mark.asyncio
async def test_azure_openai_jailbreak_filter_maps_to_injection(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test",
        AZURE_OPENAI_API_KEY="test-key",
    )

    response = httpx.Response(
        400,
        request=httpx.Request("POST", "https://aoai.example.test"),
        json={
            "error": {
                "code": "content_filter",
                "innererror": {
                    "content_filter_result": {
                        "jailbreak": {"detected": True, "filtered": True}
                    }
                },
            }
        },
    )

    async def create_completion(**kwargs):
        raise module._fake_openai.BadRequestError(response)

    module._state["client"] = types.SimpleNamespace(
        chat=types.SimpleNamespace(
            completions=types.SimpleNamespace(create=create_completion)
        )
    )
    module._state["system_prompt"] = "Classify this text."
    result = await module._classify_azure_openai("candidate text")

    assert result.injection is True
    assert result.label == "YES"
    assert result.score == 1.0
    assert "jailbreak" in result.reason.lower()


@pytest.mark.asyncio
async def test_azure_openai_non_jailbreak_filter_maps_to_safe(
    monkeypatch: pytest.MonkeyPatch,
):
    module = _load_stage2_main(
        monkeypatch,
        STAGE2_BACKEND="azure_openai",
        AZURE_OPENAI_ENDPOINT="https://aoai.example.test",
        AZURE_OPENAI_API_KEY="test-key",
    )

    response = httpx.Response(
        400,
        request=httpx.Request("POST", "https://aoai.example.test"),
        json={
            "error": {
                "code": "content_filter",
                "innererror": {
                    "content_filter_result": {
                        "jailbreak": {"detected": False, "filtered": False},
                        "self_harm": {"filtered": True, "severity": "medium"},
                    }
                },
            }
        },
    )

    async def create_completion(**kwargs):
        raise module._fake_openai.BadRequestError(response)

    module._state["client"] = types.SimpleNamespace(
        chat=types.SimpleNamespace(
            completions=types.SimpleNamespace(create=create_completion)
        )
    )
    module._state["system_prompt"] = "Classify this text."
    result = await module._classify_azure_openai("candidate text")

    assert result.injection is False
    assert result.label == "NO"
    assert result.score == 0.0
    assert "non-jailbreak" in result.reason.lower()


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
