"""AAD smoke test for shared Cognitive Services auth."""

from __future__ import annotations

import asyncio

import pytest
from azure.core.exceptions import ClientAuthenticationError
from azure.identity import CredentialUnavailableError

from contentshield.auth import COGNITIVE_SERVICES_SCOPE, DEFAULT_AZURE_CREDENTIAL

pytestmark = pytest.mark.e2e


def test_default_credential_gets_cognitive_services_token() -> None:
    try:
        token = asyncio.run(
            DEFAULT_AZURE_CREDENTIAL.get_token(COGNITIVE_SERVICES_SCOPE)
        )
    except (CredentialUnavailableError, ClientAuthenticationError) as exc:
        pytest.skip(f"e2e skipped: Azure login/token unavailable: {exc.__class__.__name__}")
    assert token.token
