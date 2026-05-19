"""Query detector — finds SQL and KQL queries embedded in text.

In-process, no HTTP. Pipeline error handling treats failures as fail-open
(detector returns ``status=failed`` and the verdict logic ignores it).

Approach
--------
Keyword co-occurrence scoring with structural pattern validation.

* **KQL** has a distinctive pipe-chain syntax (``Table | where ... | project ...``)
  that almost never appears in English prose.
* **SQL** has distinctive keyword pairs (``SELECT...FROM``, ``UPDATE...SET``)
  that rarely co-occur in prose. SQL detection also runs a second-pass
  ``sqlparse`` validator to confirm a candidate is parseable; on success it
  bumps confidence and records ``sqlparse_confirmed`` evidence.

The detector returns a normalized :class:`DetectorResult` with:

* ``label`` ``INJECTION``/``SAFE``
* ``score`` 0.0-1.0 (mapped from raw co-occurrence score)
* ``attack_type`` ``sql_query``/``kql_query`` (or ``None`` when not detected)
* ``details`` containing ``language``, ``matched_patterns``, ``raw_score``,
  ``confidence``, ``extracted_query``, and ``explanation``
"""

from __future__ import annotations

import asyncio
import re
import time

import sqlparse

from contentshield.domain.models import DetectorResult, DetectorStatus

# ── KQL patterns ──────────────────────────────────────────

_KQL_PIPE_OPERATORS = re.compile(
    r"\|\s*(where|project|summarize|extend|join|count\b|take\b|top\b|sort\s+by"
    r"|order\s+by|render|mv-expand|mv-apply|parse|evaluate|sample|distinct"
    r"|serialize|invoke|getschema|facet|lookup|union|as\b|consume"
    r"|make-series|project-away|project-keep|project-rename|project-reorder)",
    re.IGNORECASE,
)
_KQL_FUNCTIONS = re.compile(
    r"\b(ago\s*\(\s*\d+[mhdsMHDS]\s*\)"
    r"|datetime\s*\(\s*['\"]?\d{4}"
    r"|bin\s*\(\s*\w+\s*,\s*\d+[mhdsMHDS]\s*\)"
    r"|toscalar\s*\(|todatetime\s*\(|tolong\s*\("
    r"|tostring\s*\(|strcat\s*\(|pack\s*\(|bag_unpack\s*\("
    r"|parse_json\s*\(|dynamic\s*\([\[\{]"
    r"|make_set\s*\(|make_list\s*\("
    r"|dcount\s*\(|countif\s*\(|sumif\s*\(|avgif\s*\("
    r"|percentile\s*\()",
    re.IGNORECASE,
)
_KQL_STRING_OPS = re.compile(
    r"\b(has|!has|has_cs|!has_cs|hasprefix|!hasprefix"
    r"|hassuffix|!hassuffix|has_any|has_all"
    r"|contains_cs|!contains_cs|startswith_cs|endswith_cs"
    r"|matches\s+regex)\b",
    re.IGNORECASE,
)
_KQL_LET = re.compile(r"^\s*let\s+\w+\s*=", re.IGNORECASE | re.MULTILINE)
_KQL_TABLE_PIPE = re.compile(r"^\s*(\w+(?:\.\w+)?)\s*\n?\s*\|", re.MULTILINE)
_KQL_COMMENT = re.compile(r"//[^\n]*$", re.MULTILINE)


def _score_kql(text: str) -> tuple[float, list[str]]:
    """Return ``(raw_score, matched_patterns)`` for KQL detection."""
    score = 0.0
    matched: list[str] = []

    pipes = _KQL_PIPE_OPERATORS.findall(text)
    if pipes:
        score += len(pipes) * 3
        matched.append(
            f"pipe_operators: {', '.join(sorted({m.strip() for m in pipes[:5]}))}"
        )

    funcs = _KQL_FUNCTIONS.findall(text)
    if funcs:
        score += len(funcs) * 3
        matched.append(
            f"kql_functions: {', '.join(sorted({m.strip()[:30] for m in funcs[:5]}))}"
        )

    strs = _KQL_STRING_OPS.findall(text)
    if strs:
        score += len(strs) * 2
        matched.append(f"string_operators: {', '.join(sorted(set(strs[:5])))}")

    lets = _KQL_LET.findall(text)
    if lets:
        score += len(lets) * 2
        matched.append(f"let_statements: {len(lets)}")

    tables = _KQL_TABLE_PIPE.findall(text)
    if tables:
        score += len(tables) * 4
        matched.append(f"table_pipe: {', '.join(sorted(set(tables[:5])))}")

    comments = _KQL_COMMENT.findall(text)
    if comments:
        score += len(comments) * 1
        matched.append(f"kql_comments: {len(comments)}")

    return score, matched


def _confidence_kql(score: float) -> float:
    """Map raw KQL score to 0.0-0.99 confidence (PoC formula)."""
    if score >= 5:
        return min(0.5 + (score - 5) * 0.05, 0.99)
    if score >= 3:
        return 0.3 + (score - 3) * 0.1
    return score * 0.1


def _extract_kql(text: str) -> str | None:
    """Best-effort extraction of KQL query region from surrounding prose."""
    lines = text.split("\n")
    scored: list[tuple[int, int]] = []
    for i, line in enumerate(lines):
        s = 0
        if _KQL_PIPE_OPERATORS.search(line):
            s += 3
        if _KQL_FUNCTIONS.search(line):
            s += 3
        if _KQL_TABLE_PIPE.search(line):
            s += 4
        if _KQL_LET.search(line):
            s += 2
        if _KQL_STRING_OPS.search(line):
            s += 2
        if _KQL_COMMENT.search(line):
            s += 1
        scored.append((i, s))

    best_start: int | None = None
    best_end: int | None = None
    best_total = 0
    current_start: int | None = None
    current_total = 0

    for i, s in scored:
        if s > 0:
            if current_start is None:
                current_start = i
                current_total = s
            else:
                current_total += s
        else:
            if current_start is not None and current_total > best_total:
                best_start = current_start
                best_end = i
                best_total = current_total
            if current_start is not None and i - current_start <= 2:
                continue
            current_start = None
            current_total = 0

    if current_start is not None and current_total > best_total:
        best_start = current_start
        best_end = len(lines)

    if best_start is not None:
        start_line = max(0, best_start - 1)
        return "\n".join(lines[start_line:best_end]).strip()
    return None


# ── SQL patterns ──────────────────────────────────────────

# Single-column projection branch ends in ``[\w.]+\s+FROM\b`` (not ``[\w.]+``)
# to avoid matching benign prose like "select an option from the menu".
_SQL_SELECT_FROM = re.compile(
    r"\bSELECT\b"
    r"(\s+(DISTINCT|TOP\s+\d+|ALL)\s+)?"
    r"\s*"
    r"(\*|\w+\s*\(|[\w.]+\s*(,|\bAS\b)|[\w.]+\s+\w+\s*,|[\w.]+\s+FROM\b)"
    r"[\s\S]{0,500}?\bFROM\b",
    re.IGNORECASE,
)
_SQL_INSERT_INTO = re.compile(r"\bINSERT\s+INTO\b", re.IGNORECASE)
_SQL_UPDATE_SET = re.compile(r"\bUPDATE\s+\w+\s+SET\b", re.IGNORECASE)
_SQL_DELETE_FROM = re.compile(r"\bDELETE\s+\w*\s*FROM\b", re.IGNORECASE)
_SQL_EXEC = re.compile(r"\bEXEC(?:UTE)?\s+\w+", re.IGNORECASE)
_SQL_BRACKET_SELECT = re.compile(
    r"\bSELECT\b[\s\S]{1,500}?\bFROM\s+\[", re.IGNORECASE
)
_SQL_DDL = re.compile(
    r"\b(CREATE|DROP|ALTER|TRUNCATE)\s+"
    r"(TABLE|INDEX|VIEW|DATABASE|SCHEMA|PROCEDURE|FUNCTION)\b",
    re.IGNORECASE,
)
_SQL_JOIN_ON = re.compile(
    r"\b(INNER|LEFT|RIGHT|FULL|CROSS)?\s*JOIN\b[\s\S]{1,300}?\bON\b",
    re.IGNORECASE,
)
_SQL_GROUP_BY = re.compile(r"\bGROUP\s+BY\b", re.IGNORECASE)
_SQL_ORDER_BY = re.compile(r"\bORDER\s+BY\b", re.IGNORECASE)
_SQL_HAVING = re.compile(r"\bHAVING\b", re.IGNORECASE)
# Trailing ``\b`` on word operators (LIKE, BETWEEN) keeps prose like
# "where x = y" from matching while still allowing ``WHERE name LIKE '%x%'``.
_SQL_WHERE_CLAUSE = re.compile(
    r"\bWHERE\b\s+\w+\s*"
    r"(=|!=|<>|>=|<=|>|<|LIKE|IN\s*\(|IS\s+NULL|IS\s+NOT\s+NULL|BETWEEN)\b",
    re.IGNORECASE,
)
_SQL_UNION = re.compile(r"\bUNION\s+(ALL\s+)?SELECT\b", re.IGNORECASE)
_SQL_FUNCTIONS = re.compile(
    r"\b(COUNT|SUM|AVG|MIN|MAX|COALESCE|CAST|CONVERT|ISNULL|NULLIF"
    r"|GETDATE|DATEADD|DATEDIFF|SUBSTRING|CHARINDEX|REPLACE|UPPER|LOWER|TRIM|LEN"
    r"|ROW_NUMBER|RANK|DENSE_RANK)\s*\(",
    re.IGNORECASE,
)
_SQL_COMPARISON = re.compile(r"\w+\s*(=|!=|<>|>=|<=)\s*('[^']*'|@\w+|\d+)")


def _score_sql(text: str) -> tuple[float, list[str]]:
    """Return ``(raw_score, matched_patterns)`` for SQL detection."""
    score = 0.0
    matched: list[str] = []

    if _SQL_SELECT_FROM.search(text):
        score += 5
        matched.append("SELECT...FROM")
    if _SQL_INSERT_INTO.search(text):
        score += 5
        matched.append("INSERT INTO")
    if _SQL_UPDATE_SET.search(text):
        score += 5
        matched.append("UPDATE...SET")
    if _SQL_DELETE_FROM.search(text):
        score += 5
        matched.append("DELETE FROM")

    ddl = _SQL_DDL.findall(text)
    if ddl:
        score += 5
        matched.append(f"DDL: {' '.join(d[0] + ' ' + d[1] for d in ddl[:3])}")

    if _SQL_UNION.search(text):
        score += 4
        matched.append("UNION SELECT")
    if _SQL_EXEC.search(text):
        score += 5
        matched.append("EXEC")
    if _SQL_BRACKET_SELECT.search(text):
        score += 5
        matched.append("SELECT with [bracket] identifiers")
    if _SQL_JOIN_ON.search(text):
        score += 3
        matched.append("JOIN...ON")
    if _SQL_WHERE_CLAUSE.search(text):
        score += 3
        matched.append("WHERE clause with operator")
    if _SQL_GROUP_BY.search(text):
        score += 2
        matched.append("GROUP BY")
    if _SQL_ORDER_BY.search(text):
        score += 2
        matched.append("ORDER BY")
    if _SQL_HAVING.search(text):
        score += 2
        matched.append("HAVING")

    funcs = _SQL_FUNCTIONS.findall(text)
    if funcs:
        score += min(len(funcs) * 2, 6)
        matched.append(f"SQL functions: {', '.join(sorted(set(funcs[:5])))}")

    comps = _SQL_COMPARISON.findall(text)
    if comps:
        score += min(len(comps), 3)
        matched.append(f"comparisons: {len(comps)}")

    return score, matched


def _confidence_sql(score: float) -> float:
    """Map raw SQL score to 0.0-0.99 confidence (PoC formula)."""
    if score >= 5:
        return min(0.5 + (score - 5) * 0.04, 0.99)
    if score >= 3:
        return 0.3 + (score - 3) * 0.1
    return score * 0.1


# ── SQL extraction (sqlparse-backed) ──────────────────────

_SQL_START_ANCHORS = re.compile(
    r"\b(SELECT\b|INSERT\s+INTO\b|UPDATE\s+\w+\s+SET\b|DELETE\s+\w*\s*FROM\b"
    r"|CREATE\s+(?:TABLE|INDEX|VIEW|DATABASE|SCHEMA|PROCEDURE|FUNCTION)\b"
    r"|DROP\s+(?:TABLE|INDEX|VIEW|DATABASE|SCHEMA|PROCEDURE|FUNCTION)\b"
    r"|ALTER\s+(?:TABLE|INDEX|VIEW|DATABASE|SCHEMA|PROCEDURE|FUNCTION)\b"
    r"|TRUNCATE\s+TABLE\b|MERGE\s+INTO\b"
    r"|EXEC(?:UTE)?\s+(?:xp_|sp_)\w+|WITH\s+\w+\s+AS\s*\()",
    re.IGNORECASE,
)

_SQL_KEYWORDS = frozenset({
    "select", "from", "where", "and", "or", "not", "in", "between",
    "like", "is", "null", "as", "on", "join", "inner", "left", "right",
    "full", "cross", "outer", "group", "order", "by", "having", "limit",
    "offset", "top", "distinct", "all", "union", "except", "intersect",
    "asc", "desc", "set", "values", "into", "insert", "update", "delete",
    "exists", "case", "when", "then", "else", "end", "count", "sum",
    "avg", "min", "max", "coalesce", "cast", "convert", "isnull",
    "nullif", "getdate", "dateadd", "datediff", "substring", "charindex",
    "replace", "upper", "lower", "trim", "len", "row_number", "rank",
    "dense_rank", "over", "partition", "with", "recursive", "merge",
    "using", "matched", "truncate", "schema", "database", "create",
    "drop", "alter", "table", "index", "view", "primary", "key",
    "foreign", "references", "int", "bigint", "varchar", "nvarchar",
    "char", "text", "float", "decimal", "datetime", "bit", "boolean",
    "if", "begin", "declare", "exec", "execute", "procedure", "function",
    "returns", "identity", "default", "include",
    "year", "month", "day", "hour", "minute", "second",
    "nonclustered", "clustered", "unique", "constraint", "check",
    "add", "column", "output", "inserted", "deleted",
})


def _extract_sql_boundary(text: str) -> str | None:
    """Find where SQL starts and ends in mixed text (PoC heuristic walker).

    Strategy: anchor on a SQL start keyword, then walk forward token-by-token.
    Keep going while tokens look like SQL (keywords, operators, identifiers
    after keywords). Stop after 3 consecutive non-keyword identifiers, on
    unmatched closing paren, or at semicolon.
    """
    anchor = _SQL_START_ANCHORS.search(text)
    if not anchor:
        return None

    start = anchor.start()
    end = start
    consecutive_unknown = 0
    paren_depth = 0
    found_semicolon = False
    in_case_block = 0

    i = start
    while i < len(text):
        c = text[i]

        if c in " \t\r\n":
            i += 1
            end = i
            continue

        if c == ";":
            end = i + 1
            found_semicolon = True
            break

        if c == "(":
            paren_depth += 1
            i += 1
            end = i
            consecutive_unknown = 0
            continue
        if c == ")":
            paren_depth -= 1
            if paren_depth < 0:
                break
            i += 1
            end = i
            consecutive_unknown = 0
            if paren_depth == 0:
                rest = text[i:].lstrip()
                if rest:
                    next_is_sql = re.match(
                        r"(?:WHERE|AND|OR|ON|SET|VALUES|ORDER|GROUP|HAVING|UNION|"
                        r"AS|FROM|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|INTO|OVER|"
                        r"BETWEEN|LIKE|IN|NOT|IS|THEN|ELSE|END|WHEN|"
                        r";|,|\)|=|!=|<>|>=|<=|>|<|\+|-|\*|/|"
                        r"SELECT|INSERT|UPDATE|DELETE|"
                        r"\w+\s*(?:,|=|!=|<>|>=|<=|>|<|\())",
                        rest, re.IGNORECASE,
                    )
                    if not next_is_sql:
                        break
            continue

        if c in ",*=<>!+-/%":
            two = text[i:i + 2]
            if two in ("!=", "<>", ">=", "<="):
                i += 2
            elif two == "--":
                newline = text.find("\n", i)
                if newline == -1:
                    end = i
                    found_semicolon = True
                    break
                next_line = text[newline + 1:].lstrip()
                next_line_sql = re.match(
                    r"(\w+\.)?(\w+)\s*(--|=|!=|<>|>=|<=|>|<|,|\(|\)|\*)|"
                    r"\b(SELECT|FROM|WHERE|AND|OR|JOIN|GROUP|ORDER|HAVING|"
                    r"INSERT|UPDATE|DELETE|SET|VALUES|ON|INTO|AS|UNION|"
                    r"INNER|LEFT|RIGHT|FULL|CROSS|CASE|WHEN|THEN|ELSE|END|"
                    r"NOT|IN|BETWEEN|LIKE|IS|NULL|EXISTS)\b",
                    next_line, re.IGNORECASE,
                )
                if next_line_sql:
                    i = newline + 1
                    end = i
                    continue
                end = i
                found_semicolon = True
                break
            else:
                i += 1
            end = i
            consecutive_unknown = 0
            continue

        if c == "'":
            j = i + 1
            while j < len(text):
                if text[j] == "'" and (j + 1 >= len(text) or text[j + 1] != "'"):
                    break
                if text[j] == "'" and j + 1 < len(text) and text[j + 1] == "'":
                    j += 2
                    continue
                j += 1
            i = j + 1
            end = i
            consecutive_unknown = 0
            continue

        if c in ('"', '['):
            close = '"' if c == '"' else ']'
            j = text.find(close, i + 1)
            if j == -1:
                break
            i = j + 1
            end = i
            consecutive_unknown = 0
            continue

        if c == "@":
            j = i + 1
            while j < len(text) and (text[j].isalnum() or text[j] == "_"):
                j += 1
            i = j
            end = i
            consecutive_unknown = 0
            continue

        if c.isdigit():
            j = i
            while j < len(text) and (text[j].isdigit() or text[j] == "."):
                j += 1
            i = j
            end = i
            consecutive_unknown = 0
            continue

        if c.isalpha() or c == "_":
            j = i
            while j < len(text) and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            word_lower = word.lower()

            if j < len(text) and text[j] == ".":
                j += 1
                while j < len(text) and (text[j].isalnum() or text[j] == "_"):
                    j += 1
                i = j
                end = i
                consecutive_unknown = 0
                continue

            if word_lower in _SQL_KEYWORDS:
                if word_lower == "case":
                    in_case_block += 1
                elif word_lower == "end" and in_case_block > 0:
                    in_case_block -= 1

                if word_lower in ("and", "or") and paren_depth == 0:
                    lookahead = text[j:j + 60].lstrip()
                    sql_after_conj = re.match(
                        r"((\w+\.)?(\w+)\s*"
                        r"(=|!=|<>|>=|<=|>|<|IS\b|IN\b|LIKE\b|BETWEEN\b|NOT\b|EXISTS\b|\()"
                        r"|NOT\b|EXISTS\b|\(|'[^']*'|\d|@\w)",
                        lookahead, re.IGNORECASE,
                    )
                    if not sql_after_conj:
                        break
                elif word_lower == "then" and in_case_block <= 0 and paren_depth == 0:
                    lookahead = text[j:j + 40].lstrip()
                    sql_after_then = re.match(
                        r"('[^']*'|\d+|\w+\s*\(|NULL\b|CASE\b)",
                        lookahead, re.IGNORECASE,
                    )
                    if not sql_after_then:
                        break

                i = j
                end = i
                consecutive_unknown = 0
                continue
            else:
                consecutive_unknown += 1
                if consecutive_unknown >= 3:
                    break
                i = j
                end = i
                continue

        break

    extracted = text[start:end].strip()
    if not found_semicolon and extracted:
        while True:
            m = re.search(r"\s+(\w+)\.?\s*$", extracted)
            if not m:
                break
            last_word = m.group(1).lower().rstrip(".")
            if last_word in _SQL_KEYWORDS or re.match(r"^\d+$", last_word):
                break
            before = extracted[:m.start()].rstrip()
            prev = re.search(r"(\w+)\s*$", before)
            if prev and prev.group(1).lower() in _SQL_KEYWORDS:
                break
            extracted = before
            if len(extracted) < 10:
                break

    return extracted if len(extracted) > 5 else None


def _extract_and_validate_sql(text: str) -> tuple[str | None, bool]:
    """Extract a SQL candidate and validate with sqlparse.

    Returns ``(extracted_or_None, parsed_ok)``. ``parsed_ok`` is True when
    sqlparse recognized the candidate as a typed statement.
    """
    candidate = _extract_sql_boundary(text)
    if not candidate:
        return None, False
    try:
        parsed = sqlparse.parse(candidate)
        if parsed and parsed[0].get_type() not in (None, "UNKNOWN"):
            return candidate, True
    except Exception:  # fail-open: parser errors are not detector errors
        pass
    return candidate, False


# ── Public API ────────────────────────────────────────────

_KQL_THRESHOLD = 3.0
_SQL_THRESHOLD = 5.0


async def detect(text: str) -> DetectorResult:
    """Detect SQL/KQL queries in *text*.

    Returns a :class:`DetectorResult` named ``"query_detect"``. The chosen
    language is whichever of SQL/KQL has the higher confidence (when both
    cross their threshold); otherwise the one that crossed; otherwise none.
    """
    return await asyncio.to_thread(_detect_sync, text)


def _detect_sync(text: str) -> DetectorResult:
    """Run the synchronous query detection work."""
    start_ns = time.monotonic_ns()

    kql_score, kql_matched = _score_kql(text)
    sql_score, sql_matched = _score_sql(text)
    kql_conf = _confidence_kql(kql_score)
    sql_conf = _confidence_sql(sql_score)

    kql_detected = kql_score >= _KQL_THRESHOLD
    sql_detected = sql_score >= _SQL_THRESHOLD

    extracted_query: str | None = None
    sqlparse_confirmed = False

    if sql_detected:
        extracted_query, sqlparse_confirmed = _extract_and_validate_sql(text)
        if sqlparse_confirmed:
            sql_conf = min(sql_conf + 0.1, 0.99)
            sql_matched.append("sqlparse_confirmed")

    if kql_detected and (not sql_detected or kql_conf >= sql_conf):
        language = "kql"
        confidence = kql_conf
        matched = kql_matched
        raw_score = kql_score
        extracted_query = _extract_kql(text)
    elif sql_detected:
        language = "sql"
        confidence = sql_conf
        matched = sql_matched
        raw_score = sql_score
    else:
        language = "none"
        confidence = max(kql_conf, sql_conf)
        matched = kql_matched + sql_matched
        raw_score = max(kql_score, sql_score)
        extracted_query = None

    detected = language != "none"
    elapsed_ms = (time.monotonic_ns() - start_ns) // 1_000_000
    threshold = _KQL_THRESHOLD if language == "kql" else _SQL_THRESHOLD
    explanation = (
        f"{language.upper() if detected else 'No query'} detected "
        f"(score={raw_score:.1f}, threshold={threshold:.0f})."
    )

    return DetectorResult(
        name="query_detect",
        detected=detected,
        label="INJECTION" if detected else "SAFE",
        score=round(min(confidence, 1.0), 2),
        status=DetectorStatus.COMPLETED,
        latency_ms=elapsed_ms,
        attack_type=f"{language}_query" if detected else None,
        reason=explanation,
        details={
            "language": language,
            "matched_patterns": matched,
            "raw_score": round(raw_score, 1),
            "confidence": round(confidence, 2),
            "extracted_query": extracted_query,
            "explanation": explanation,
        },
    )
