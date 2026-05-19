"""Separator-first recursive text chunker for the Stage-1 residual detector.

Ported from RatioAI.PromptInjection PoC (AppA/residual_classifier/chunker.py).
The algorithm and defaults are locked by Section 10 of the Stage-1 spec; do
not change them without explicit approval.

Algorithm (Section 5):
  1. Split on hard separators in priority order: blank line, single newline,
     '. ', '! ', '? '.
  2. For any fragment exceeding MAX_WORDS, apply fixed-size word split with
     OVERLAP_WORDS of context.
  3. If total chunks exceed MAX_CHUNKS, keep ceil(MAX_CHUNKS/2) head and
     floor(MAX_CHUNKS/2) tail (injections cluster at start or end).
  4. Deduplicate while preserving order.

Tunable via env vars:
  STAGE1_MAX_TOKENS_PER_CHUNK   max words per chunk (default 200)
  STAGE1_CHUNK_OVERLAP_WORDS    word overlap between split chunks (default 20)
  STAGE1_MAX_CHUNKS             hard cap on chunk count (default 8)
"""

from __future__ import annotations

import math
import os

DEFAULT_MAX_WORDS = 200
DEFAULT_OVERLAP_WORDS = 20
DEFAULT_MAX_CHUNKS = 8

_SEPARATORS = ["\n\n", "\n", ". ", "! ", "? "]


def chunk_text(text: str) -> list[str]:
    """Split text into at most MAX_CHUNKS semantically-coherent chunks."""
    if not text or not text.strip():
        return []

    max_words = _int_env("STAGE1_MAX_TOKENS_PER_CHUNK", DEFAULT_MAX_WORDS)
    overlap_words = _int_env("STAGE1_CHUNK_OVERLAP_WORDS", DEFAULT_OVERLAP_WORDS)
    max_chunks = _int_env("STAGE1_MAX_CHUNKS", DEFAULT_MAX_CHUNKS)

    raw_fragments = _split_by_separators(text)

    refined: list[str] = []
    for frag in raw_fragments:
        if _word_count(frag) > max_words:
            refined.extend(_fixed_word_split(frag, max_words, overlap_words))
        else:
            refined.append(frag)

    seen: set[str] = set()
    unique: list[str] = []
    for chunk in refined:
        if chunk not in seen and chunk.strip():
            seen.add(chunk)
            unique.append(chunk)

    if len(unique) > max_chunks:
        head_n = math.ceil(max_chunks / 2)
        tail_n = math.floor(max_chunks / 2)
        unique = unique[:head_n] + unique[-tail_n:]

    return unique


def _split_by_separators(text: str) -> list[str]:
    """Split on the highest-priority separator that yields more than one part."""
    for sep in _SEPARATORS:
        parts = text.split(sep)
        if len(parts) > 1:
            fragments: list[str] = []
            last_index = len(parts) - 1
            for i, part in enumerate(parts):
                stripped = part.strip()
                if not stripped:
                    continue
                fragments.append(
                    stripped if i == last_index else stripped + sep.rstrip()
                )
            if fragments:
                return fragments

    stripped = text.strip()
    return [stripped] if stripped else []


def _word_count(text: str) -> int:
    return len(text.split())


def _fixed_word_split(text: str, max_words: int, overlap: int) -> list[str]:
    """Sliding-window fallback splitter for fragments over max_words."""
    words = text.split()
    stride = max(max_words - overlap, 1)
    chunks: list[str] = []
    start = 0
    while start < len(words):
        chunks.append(" ".join(words[start : start + max_words]))
        start += stride
        if start >= len(words):
            break
    return chunks


def _int_env(name: str, default: int) -> int:
    value = os.getenv(name, "").strip()
    if not value:
        return default
    return int(value)
