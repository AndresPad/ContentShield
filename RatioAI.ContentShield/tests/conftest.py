"""Shared pytest fixtures for ContentShield tests."""

from __future__ import annotations

import pytest

_LIVE_DETECTOR_ENV_VARS = (
    "CONTENT_SAFETY_ENDPOINT",
    "CONTENT_SAFETY_API_VERSION",
    "CONTENT_SAFETY_TIMEOUT_SECONDS",
    "CONTENT_SAFETY_KEY",
    "STAGE1_AOAI_ENDPOINT",
    "STAGE1_AOAI_EMBEDDING_DEPLOYMENT",
    "STAGE1_AOAI_API_VERSION",
    "STAGE1_AOAI_TIMEOUT_SECONDS",
    "STAGE1_AOAI_KEY",
    "STAGE1_DECISION_THRESHOLD",
    "STAGE1_EARLY_STOP_THRESHOLD",
    "SLM_ENDPOINT",
    "SLM_PATH",
    "SLM_TIMEOUT_SECONDS",
    "SLM_MODEL",
)

_LIVE_TEST_MARKERS = ("e2e", "integration")


@pytest.fixture(autouse=True)
def _clear_live_detector_env(
    monkeypatch: pytest.MonkeyPatch,
    request: pytest.FixtureRequest,
) -> None:
    """Keep unit/API tests from inheriting local live detector configuration."""
    if any(request.node.get_closest_marker(marker) for marker in _LIVE_TEST_MARKERS):
        return

    for name in _LIVE_DETECTOR_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
