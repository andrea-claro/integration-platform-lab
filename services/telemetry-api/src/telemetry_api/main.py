"""Entry point: wire settings, store, consumer and run uvicorn (handles SIGTERM gracefully)."""

from __future__ import annotations

import uvicorn

from .app import create_app
from .config import Settings
from .consumer import TelemetryConsumer
from .observability import configure_logging
from .store import TelemetryStore


def main() -> None:
    settings = Settings.from_env()
    configure_logging("telemetry-api", settings.log_level)
    store = TelemetryStore(max_devices=settings.max_devices)
    consumer = TelemetryConsumer(settings, store)
    app = create_app(store, consumer)
    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 (in-container)
        port=settings.http_port,
        log_config=None,
        proxy_headers=True,
        forwarded_allow_ips="*",
        timeout_graceful_shutdown=10,
    )
