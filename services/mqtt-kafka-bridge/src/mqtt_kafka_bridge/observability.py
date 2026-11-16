"""Structured JSON logging and a tiny HTTP server for /healthz, /readyz and /metrics."""

from __future__ import annotations

import json
import logging
import re
import sys
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

_RESERVED = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime", "color_message"}
_DIGITS = re.compile(r"\d+")


class JsonFormatter(logging.Formatter):
    """One JSON object per line; extra={...} fields are merged into the object."""

    def __init__(self, service: str) -> None:
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname.lower(),
            "service": self.service,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        entry.update({k: v for k, v in record.__dict__.items() if k not in _RESERVED})
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


class DedupFilter(logging.Filter):
    """Collapse repeated WARNING+ lines (e.g. a reconnect loop) to one per window.

    The next line let through after a quiet window carries `suppressed: N`.
    """

    def __init__(self, window_seconds: float = 30.0) -> None:
        super().__init__()
        self.window = window_seconds
        self._seen: dict[tuple, list] = {}
        self._lock = threading.Lock()

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno < logging.WARNING:
            return True
        message = _DIGITS.sub("#", record.getMessage())[:120]
        key = (record.name, record.levelno, message, getattr(record, "code", None))
        now = time.monotonic()
        with self._lock:
            entry = self._seen.get(key)
            if entry and now - entry[0] < self.window:
                entry[1] += 1
                return False
            if entry and entry[1]:
                record.suppressed = entry[1]
            if len(self._seen) > 1000:
                self._seen.clear()
            self._seen[key] = [now, 0]
        return True


def configure_logging(service: str, level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    handler.addFilter(DedupFilter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())


Check = Callable[[], tuple[bool, dict]]


class HealthServer:
    """Serves liveness, readiness and Prometheus metrics on one port."""

    def __init__(self, port: int, liveness: Check, readiness: Check) -> None:
        checks = {"/healthz": liveness, "/readyz": readiness}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # http.server API name
                path = self.path.split("?", 1)[0]
                if path == "/metrics":
                    self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
                elif path in checks:
                    ok, details = checks[path]()
                    body = json.dumps({"status": "ok" if ok else "fail", **details}).encode()
                    self._send(200 if ok else 503, body, "application/json")
                else:
                    self._send(404, b'{"status":"not found"}', "application/json")

            def _send(self, code: int, body: bytes, content_type: str) -> None:
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: object) -> None:  # probes would flood the logs
                return

        self._server = ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104 (in-container)
        self._thread = threading.Thread(target=self._server.serve_forever, name="http", daemon=True)

    @property
    def port(self) -> int:
        return self._server.server_address[1]

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
