"""Fixtures for cloud-backed ContentShield e2e tests."""

from __future__ import annotations

import pytest
from dotenv import find_dotenv, load_dotenv

from contentshield.config import get_acs_config, get_aoai_config, get_stage2_config

load_dotenv(find_dotenv(filename=".env", usecwd=False), override=False)


@pytest.fixture(scope="session")
def acs_config():
    config = get_acs_config()
    if config is None:
        pytest.skip("e2e skipped: CONTENT_SAFETY_ENDPOINT is not configured")
    return config


@pytest.fixture(scope="session")
def aoai_config():
    config = get_aoai_config()
    if config is None:
        pytest.skip("e2e skipped: STAGE1_AOAI_ENDPOINT is not configured")
    return config


@pytest.fixture(scope="session")
def stage2_config():
    config = get_stage2_config()
    if config is None:
        pytest.skip("e2e skipped: SLM_ENDPOINT is not configured")
    return config
