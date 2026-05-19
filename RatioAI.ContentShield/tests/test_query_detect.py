"""Behavioral tests for the query_detect detector."""

from __future__ import annotations

import asyncio

import pytest

from contentshield.domain.models import DetectorStatus
from contentshield.infrastructure.query_detect import detect

pytestmark = pytest.mark.legacy_pipeline


def _run(text: str):
    return asyncio.run(detect(text))


class TestSQLDetection:
    def test_select_from(self):
        r = _run("SELECT name, email FROM users WHERE active = 1")
        assert r.detected is True
        assert r.label == "INJECTION"
        assert r.details["language"] == "sql"

    def test_drop_table(self):
        r = _run("DROP TABLE students; --")
        assert r.detected is True

    def test_insert_into(self):
        r = _run("INSERT INTO logs (msg) VALUES ('pwned')")
        assert r.detected is True


class TestKQLDetection:
    def test_pipe_chain(self):
        r = _run("SecurityEvent | where TimeGenerated > ago(1h) | summarize count()")
        assert r.detected is True
        assert r.details["language"] == "kql"

    def test_table_pipe(self):
        r = _run("Heartbeat\n| where Computer has 'web'\n| project Computer, TimeGenerated")
        assert r.detected is True


class TestBenign:
    def test_prose(self):
        r = _run("Please help me reset my password for the admin portal.")
        assert r.detected is False

    def test_short(self):
        r = _run("hello")
        assert r.detected is False

    def test_english_with_keywords(self):
        r = _run("I want to select an option from the dropdown menu.")
        assert r.detected is False

    def test_prose_with_select_keyword(self):
        # Regression: bare "select ... from ..." in English prose must not
        # trigger SQL detection. sqlparse acts as the second-pass validator.
        r = _run("Please select an option from the menu and submit it.")
        assert r.detected is False
        assert r.details["language"] == "none"


class TestSqlparseValidation:
    def test_real_sql_is_confirmed(self):
        r = _run(
            "Here is the query: SELECT id, name FROM users WHERE active = 1;"
        )
        assert r.detected is True
        assert "sqlparse_confirmed" in r.details["matched_patterns"]
        assert r.details["extracted_query"] is not None
        assert "SELECT" in r.details["extracted_query"].upper()


class TestResultShape:
    def test_positive_has_patterns(self):
        r = _run("SELECT * FROM users")
        assert r.detected is True
        assert r.details is not None
        assert len(r.details["matched_patterns"]) > 0

    def test_always_completed(self):
        r = _run("anything")
        assert r.status == DetectorStatus.COMPLETED
        assert r.name == "query_detect"

    def test_score_in_bounds(self):
        r = _run("SELECT * FROM users WHERE id = 1")
        assert 0.0 <= r.score <= 1.0

    def test_details_carry_extracted_query_for_kql(self):
        r = _run(
            "Heartbeat\n| where Computer has 'web'\n| project Computer, TimeGenerated"
        )
        assert r.detected is True
        assert r.details["extracted_query"] is not None
        assert "Heartbeat" in r.details["extracted_query"]
