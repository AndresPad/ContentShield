"""Azure OpenAI embedding client for the Stage-1 residual detector."""

from __future__ import annotations

from typing import Any

import httpx
import numpy as np
from azure.core.exceptions import ClientAuthenticationError
from azure.identity import CredentialUnavailableError

from contentshield.auth import COGNITIVE_SERVICES_SCOPE, DEFAULT_AZURE_CREDENTIAL
from contentshield.config import AOAIConfig, get_aoai_config

EMBEDDING_DIM = 1536


class AOAIConfigMissingError(Exception):
    """Raised when Stage-1 AOAI configuration is absent."""


class AOAIEmbeddingDependencyError(Exception):
    """Raised when the embedding dependency cannot be reached or authorized."""


class InvalidAOAIEmbeddingResponseError(Exception):
    """Raised when AOAI returns an unexpected embedding response shape."""


async def embed_texts(texts: list[str]) -> np.ndarray:
    """Embed a non-empty batch of texts with Azure OpenAI."""
    if not texts:
        return np.empty((0, EMBEDDING_DIM), dtype=np.float32)

    config = get_aoai_config()
    if config is None:
        raise AOAIConfigMissingError("STAGE1_AOAI_ENDPOINT is not configured")

    headers = await _aoai_headers(config)
    url = (
        f"{config.endpoint}/openai/deployments/{config.embedding_deployment}"
        f"/embeddings?api-version={config.api_version}"
    )
    payload = {"input": texts, "dimensions": EMBEDDING_DIM}

    try:
        async with httpx.AsyncClient(timeout=config.timeout_s) as client:
            response = await client.post(url, headers=headers, json=payload)
        response.raise_for_status()
        body = response.json()
    except (httpx.HTTPStatusError, httpx.RequestError) as exc:
        raise AOAIEmbeddingDependencyError(str(exc)) from exc
    except ValueError as exc:
        raise InvalidAOAIEmbeddingResponseError(str(exc)) from exc

    return _extract_embeddings(body, len(texts))


async def _aoai_headers(config: AOAIConfig) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if config.api_key:
        headers["api-key"] = config.api_key
        return headers

    try:
        token = await DEFAULT_AZURE_CREDENTIAL.get_token(COGNITIVE_SERVICES_SCOPE)
    except (ClientAuthenticationError, CredentialUnavailableError) as exc:
        raise AOAIEmbeddingDependencyError(str(exc)) from exc
    except Exception as exc:
        raise AOAIEmbeddingDependencyError(str(exc)) from exc

    headers["Authorization"] = f"Bearer {token.token}"
    return headers


def _extract_embeddings(body: Any, expected_count: int) -> np.ndarray:
    if not isinstance(body, dict):
        raise InvalidAOAIEmbeddingResponseError("AOAI response body is not an object")

    data = body.get("data")
    if not isinstance(data, list) or len(data) != expected_count:
        raise InvalidAOAIEmbeddingResponseError("AOAI response has invalid data length")

    try:
        ordered = sorted(data, key=lambda item: item["index"])
        matrix = np.array([item["embedding"] for item in ordered], dtype=np.float32)
    except (KeyError, TypeError, ValueError) as exc:
        raise InvalidAOAIEmbeddingResponseError(str(exc)) from exc

    if matrix.shape != (expected_count, EMBEDDING_DIM):
        raise InvalidAOAIEmbeddingResponseError(
            f"AOAI embedding matrix shape {matrix.shape} is invalid"
        )
    return matrix
