"""Typed environment loading for detector infrastructure."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from dotenv import find_dotenv, load_dotenv

_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_DOTENV_PATH = find_dotenv(filename=".env", usecwd=False) or str(_PROJECT_ROOT / ".env")
load_dotenv(_DOTENV_PATH, override=False)

_DEFAULT_STAGE2_PATH = "/v1/chat/completions"


@dataclass(frozen=True)
class ACSConfig:
    """Azure Content Safety Prompt Shield configuration."""

    endpoint: str
    api_version: str
    timeout_s: float
    api_key: str | None


@dataclass(frozen=True)
class AOAIConfig:
    """Azure OpenAI embedding configuration for stage-1 dependencies."""

    endpoint: str
    embedding_deployment: str
    api_version: str
    timeout_s: float
    api_key: str | None


@dataclass(frozen=True)
class Stage2Config:
    """vLLM-backed Stage2 endpoint configuration."""

    endpoint: str
    path: str
    timeout_s: float
    model: str


@dataclass(frozen=True)
class Stage1Config:
    """Stage-1 residual classifier tunables.

    ``decision_threshold`` is None by default, meaning the threshold packed
    in the joblib artifact (the training-time default) is used. Setting
    ``STAGE1_DECISION_THRESHOLD`` overrides it at runtime.
    """

    decision_threshold: float | None
    early_stop_threshold: float


def get_acs_config() -> ACSConfig | None:
    """Return ACS config, or None when the endpoint is not configured."""
    endpoint = _endpoint("CONTENT_SAFETY_ENDPOINT")
    if endpoint is None:
        return None
    return ACSConfig(
        endpoint=endpoint,
        api_version=_env("CONTENT_SAFETY_API_VERSION", "2024-09-01"),
        timeout_s=_float_env("CONTENT_SAFETY_TIMEOUT_SECONDS", 15.0),
        api_key=_optional_env("CONTENT_SAFETY_KEY"),
    )


def get_aoai_config() -> AOAIConfig | None:
    """Return AOAI config, or None when the endpoint is not configured."""
    endpoint = _endpoint("STAGE1_AOAI_ENDPOINT")
    if endpoint is None:
        return None
    return AOAIConfig(
        endpoint=endpoint,
        embedding_deployment=_env(
            "STAGE1_AOAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small"
        ),
        api_version=_env("STAGE1_AOAI_API_VERSION", "2024-02-01"),
        timeout_s=_float_env("STAGE1_AOAI_TIMEOUT_SECONDS", 15.0),
        api_key=_optional_env("STAGE1_AOAI_KEY"),
    )


def get_stage2_config() -> Stage2Config | None:
    """Return Stage2 config, or None when the endpoint is not configured."""
    endpoint_value = _endpoint("SLM_ENDPOINT")
    if endpoint_value is None:
        return None
    endpoint, inferred_path = _split_endpoint_path(endpoint_value)
    return Stage2Config(
        endpoint=endpoint,
        path=_path_env("SLM_PATH", inferred_path or _DEFAULT_STAGE2_PATH),
        timeout_s=_float_env("SLM_TIMEOUT_SECONDS", 15.0),
        model=_env("SLM_MODEL", "google/gemma-4-31b-it"),
    )


def get_stage1_config() -> Stage1Config:
    """Return Stage-1 tunables resolved from environment variables."""
    return Stage1Config(
        decision_threshold=_optional_float_env("STAGE1_DECISION_THRESHOLD"),
        early_stop_threshold=_float_env("STAGE1_EARLY_STOP_THRESHOLD", 0.90),
    )


def is_v1_ml_disabled() -> bool:
    """Return True when the V1 wiring (ACS + Stage2 only) is in effect."""
    return os.getenv("CONTENTSHIELD_V1_ML_DISABLED", "1").strip().lower() in {"1", "true", "yes"}


def _env(name: str, default: str) -> str:
    value = os.getenv(name, default).strip()
    return value or default


def _optional_env(name: str) -> str | None:
    value = os.getenv(name, "").strip()
    return value or None


def _endpoint(name: str) -> str | None:
    value = _optional_env(name)
    if value is None:
        return None
    return value.rstrip("/")


def _split_endpoint_path(endpoint: str) -> tuple[str, str | None]:
    parsed = urlsplit(endpoint)
    if not parsed.scheme or not parsed.netloc or not parsed.path.strip("/"):
        return endpoint.rstrip("/"), None

    base_endpoint = urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))
    return base_endpoint.rstrip("/"), _normalize_path(parsed.path)


def _path_env(name: str, default: str) -> str:
    value = os.getenv(name, "").strip()
    return _normalize_path(value or default)


def _normalize_path(path: str) -> str:
    value = path.strip()
    if not value:
        return "/"
    if not value.startswith("/"):
        value = f"/{value}"
    return value.rstrip("/") or "/"


def _float_env(name: str, default: float) -> float:
    value = os.getenv(name, "").strip()
    if not value:
        return default
    return float(value)


def _optional_float_env(name: str) -> float | None:
    value = os.getenv(name, "").strip()
    return float(value) if value else None
