"""Orchestrator HTTP routes.

Two routes: ``POST /v1/detect`` and ``GET /health``.
No verdict logic here — all policy lives in ``orchestrator/pipeline.py``.
"""

from __future__ import annotations

from fastapi import FastAPI, HTTPException

from contentshield.api.mappers import request_to_command, response_to_model
from contentshield.api.models import DetectRequest, DetectResponse, HealthResponse
from contentshield.domain.errors import InvalidModeError
from contentshield.orchestrator.pipeline import DetectFn, run


def register_routes(
    app: FastAPI,
    detectors: dict[str, DetectFn],
) -> None:
    """Attach ``/v1/detect`` and ``/health`` to *app*.

    Detector dict is closure-captured — no ``app.state`` usage.
    """

    @app.post("/v1/detect", response_model=DetectResponse)
    async def detect(req: DetectRequest) -> DetectResponse:
        command = request_to_command(req)
        try:
            result = await run(command, detectors)
        except InvalidModeError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return response_to_model(result)

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse()
