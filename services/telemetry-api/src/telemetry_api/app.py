"""FastAPI application: latest readings and per-device stats from the telemetry stream."""

from __future__ import annotations

import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, Protocol

from fastapi import FastAPI, HTTPException, Path, Query, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, ConfigDict

from . import __version__
from .store import TelemetryStore

DeviceId = Annotated[str, Path(pattern=r"^[A-Za-z0-9._-]{1,64}$", examples=["sensor-001"])]

HTTP_REQUESTS = Counter("api_http_requests_total", "HTTP requests", ["method", "route", "status"])
HTTP_LATENCY = Histogram(
    "api_http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)
UNTRACKED_PATHS = {"/metrics", "/healthz", "/readyz"}


class ConsumerLike(Protocol):
    kafka_up: bool

    def start(self) -> None: ...
    def stop(self, timeout: float = 10.0) -> None: ...
    def is_live(self) -> bool: ...
    def is_ready(self) -> bool: ...


class Reading(BaseModel):
    model_config = ConfigDict(extra="ignore")

    device_id: str
    seq: int | None = None
    ts: datetime
    temperature_c: float
    humidity_pct: float
    battery_pct: float
    ingested_at: datetime | None = None


class DeviceSummary(BaseModel):
    device_id: str
    last_seen: datetime
    readings: int


class MetricStats(BaseModel):
    min: float | None
    max: float | None
    avg: float | None


class DeviceStats(BaseModel):
    device_id: str
    readings: int
    first_seen: datetime
    last_seen: datetime
    temperature_c: MetricStats
    humidity_pct: MetricStats
    battery_pct: MetricStats


class Health(BaseModel):
    status: str
    kafka_up: bool | None = None
    devices: int | None = None


DESCRIPTION = """
Read-only API over the IoT telemetry stream
(simulated devices → MQTT → Kafka `telemetry.raw` → this service).

Through the public gateway every `/v1` request needs an **`x-api-key`** header and is
rate limited; both are enforced by Envoy Gateway, not by this service.
"""


def create_app(store: TelemetryStore, consumer: ConsumerLike | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        if consumer is not None:
            consumer.start()
        yield
        if consumer is not None:
            consumer.stop()

    app = FastAPI(
        title="Telemetry API",
        version=__version__,
        description=DESCRIPTION,
        lifespan=lifespan,
        license_info={"name": "MIT"},
    )

    @app.middleware("http")
    async def http_metrics(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        route = request.scope.get("route")
        template = getattr(route, "path", "unmatched")
        if template not in UNTRACKED_PATHS:
            HTTP_REQUESTS.labels(request.method, template, str(response.status_code)).inc()
            HTTP_LATENCY.labels(request.method, template).observe(time.perf_counter() - start)
        return response

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        return RedirectResponse("/docs")

    @app.get("/healthz", response_model=Health, tags=["ops"])
    def healthz() -> JSONResponse:
        """Liveness: the process and its Kafka consumer thread are running."""
        live = consumer is None or consumer.is_live()
        return JSONResponse({"status": "ok" if live else "fail"}, status_code=200 if live else 503)

    @app.get("/readyz", response_model=Health, tags=["ops"])
    def readyz() -> JSONResponse:
        """Readiness: the consumer has joined the group and the store is warm."""
        ready = consumer is None or consumer.is_ready()
        body = {
            "status": "ok" if ready else "fail",
            "kafka_up": None if consumer is None else consumer.kafka_up,
            "devices": store.device_count(),
        }
        return JSONResponse(body, status_code=200 if ready else 503)

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.get("/v1/devices", response_model=list[DeviceSummary], tags=["telemetry"])
    def list_devices() -> list[dict]:
        """All devices seen so far, with the time of their latest reading."""
        return store.devices()

    @app.get("/v1/readings/latest", response_model=list[Reading], tags=["telemetry"])
    def latest_readings(limit: Annotated[int, Query(ge=1, le=500)] = 50) -> list[dict]:
        """Latest reading of each device, most recent first."""
        return store.latest_all(limit)

    @app.get(
        "/v1/devices/{device_id}/latest",
        response_model=Reading,
        responses={404: {"description": "Unknown device"}},
        tags=["telemetry"],
    )
    def device_latest(device_id: DeviceId) -> dict:
        reading = store.latest(device_id)
        if reading is None:
            raise HTTPException(status_code=404, detail="unknown device")
        return reading

    @app.get(
        "/v1/devices/{device_id}/stats",
        response_model=DeviceStats,
        responses={404: {"description": "Unknown device"}},
        tags=["telemetry"],
    )
    def device_stats(device_id: DeviceId) -> dict:
        stats = store.stats(device_id)
        if stats is None:
            raise HTTPException(status_code=404, detail="unknown device")
        return stats

    return app
