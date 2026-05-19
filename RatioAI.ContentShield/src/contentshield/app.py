"""ContentShield service — composition root.

Reading order:
    app.py                    ← you are here (composition)
    api/routes.py             ← HTTP transport
    api/models.py             ← request/response models
    api/mappers.py            ← DTO ↔ domain translation
    orchestrator/pipeline.py  ← detection policy
    domain/                   ← models + errors
    infrastructure/           ← detector wiring + adapters

Run locally:
    uvicorn contentshield.app:app
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import TYPE_CHECKING

from fastapi import FastAPI

from contentshield.api import register_routes
from contentshield.auth import warm_credential
from contentshield.infrastructure.detectors import build_default_detectors

if TYPE_CHECKING:
    from collections.abc import AsyncIterator

    from contentshield.orchestrator.pipeline import DetectFn


@asynccontextmanager
async def _lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Pre-warm Azure credential at startup so first detector call is hot."""
    await warm_credential()
    yield


def create_app(detectors: dict[str, DetectFn] | None = None) -> FastAPI:
    """Wire detectors into the FastAPI app.

    *detectors* is injectable so tests can pass fakes without touching
    the default wiring.
    """
    application = FastAPI(title="ContentShield", version="0.1.0", lifespan=_lifespan)
    register_routes(
        application,
        detectors if detectors is not None else build_default_detectors(),
    )
    return application


app = create_app()
