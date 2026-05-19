"""Stage-2 vLLM service smoke test.

Skipped until CS-014 wires up a live stage2 fixture. Mirrors the original PoC
helper at `services/stage2/deploy/scripts/smoke_test.py`; lifted into the test
suite so the contract is visible to pytest and CI.
"""

from __future__ import annotations

import os

import httpx
import pytest


@pytest.mark.integration
@pytest.mark.skip(reason="requires running stage2 service; lands with CS-014 fixture")
def test_stage2_smoke() -> None:
    base_url = os.getenv("VLLM_URL") or os.getenv("VLLM_BASE_URL", "http://localhost:8000")
    api_key = os.getenv("VLLM_API_KEY", "not-required")
    model = os.getenv("MODEL_NAME", "meta-llama/Llama-3.3-70B-Instruct")

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a concise assistant."},
            {"role": "user", "content": "Reply with exactly: vllm-ok"},
        ],
        "temperature": 0.0,
        "max_tokens": 16,
    }

    headers = {"Authorization": f"Bearer {api_key}"}

    with httpx.Client(timeout=60.0) as client:
        health = client.get(f"{base_url}/health")
        health.raise_for_status()

        resp = client.post(f"{base_url}/v1/chat/completions", json=payload, headers=headers)
        resp.raise_for_status()
        body = resp.json()
        content = body["choices"][0]["message"]["content"]
        assert content
