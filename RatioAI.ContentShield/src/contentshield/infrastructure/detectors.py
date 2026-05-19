"""Default detector wiring for V1."""

from __future__ import annotations

from typing import TYPE_CHECKING

from contentshield.config import is_v1_ml_disabled
from contentshield.infrastructure.acs_prompt_shield import (
    detect as acs_prompt_shield_detect,
)
from contentshield.infrastructure.query_detect import detect as query_detect
from contentshield.infrastructure.stage1.detector import detect as stage1_detect
from contentshield.infrastructure.stage2_client import detect as stage2_detect

if TYPE_CHECKING:
    from contentshield.orchestrator.pipeline import DetectFn


def build_default_detectors() -> dict[str, DetectFn]:
    """Build the default detector dict.

    V1 (``CONTENTSHIELD_V1_ML_DISABLED=1``, default): only ACS + Stage2.
    V2 (flag unset/false): full set including stage1 and query_detect.
    """
    if is_v1_ml_disabled():
        return {
            "acs_prompt_shield": acs_prompt_shield_detect,
            "stage2": stage2_detect,
        }
    return {
        "acs_prompt_shield": acs_prompt_shield_detect,
        "stage1": stage1_detect,
        "query_detect": query_detect,
        "stage2": stage2_detect,
    }
