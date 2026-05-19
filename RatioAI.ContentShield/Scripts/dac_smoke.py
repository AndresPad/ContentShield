"""Standalone DefaultAzureCredential smoke test.

Usage:
    uv run python Scripts/dac_smoke.py

Prints "OK" with the token expires_on timestamp on success, or the
exception class on failure. Same scope and credential singleton the
shared auth module uses.
"""

from __future__ import annotations

import sys

from contentshield.auth import COGNITIVE_SERVICES_SCOPE, DEFAULT_AZURE_CREDENTIAL


def main() -> int:
    """Acquire a Cognitive Services token with the shared DAC singleton."""
    try:
        token = DEFAULT_AZURE_CREDENTIAL.get_token(COGNITIVE_SERVICES_SCOPE)
    except Exception as exc:
        print(f"DefaultAzureCredential FAIL: {exc.__class__.__name__}: {exc}")
        return 2
    print(f"DefaultAzureCredential OK; expires_on={token.expires_on}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
