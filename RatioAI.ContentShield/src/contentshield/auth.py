"""Shared Azure Cognitive Services authentication helpers."""

from __future__ import annotations

import logging

from azure.identity.aio import DefaultAzureCredential

COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"
DEFAULT_AZURE_CREDENTIAL = DefaultAzureCredential(exclude_interactive_browser_credential=True)

logger = logging.getLogger(__name__)


async def cognitive_services_headers(api_key: str | None) -> dict[str, str]:
    """Return auth headers for ACS and AOAI cognitive service calls."""
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Ocp-Apim-Subscription-Key"] = api_key
        return headers

    token = await DEFAULT_AZURE_CREDENTIAL.get_token(COGNITIVE_SERVICES_SCOPE)
    headers["Authorization"] = f"Bearer {token.token}"
    return headers


async def warm_credential() -> None:
    """Pre-fetch a Cognitive Services token at app startup.

    Eliminates cold-token latency on the first detector call. Failures here
    are logged but never raise -- detectors will retry and surface the real
    error in the response.
    """
    try:
        await DEFAULT_AZURE_CREDENTIAL.get_token(COGNITIVE_SERVICES_SCOPE)
        logger.info("Azure credential warmed for Cognitive Services scope")
    except Exception:
        logger.exception("Credential warm-up failed; detectors will retry")
