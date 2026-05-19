"""Fixtures for integration tests.

Integration tests require live external services (e.g., a running stage2 vLLM
endpoint). They are skipped by default and are scheduled to be wired up in
CS-014. See `pyproject.toml` for the `integration` pytest marker.
"""
