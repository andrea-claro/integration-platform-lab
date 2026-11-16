"""Structured JSON logging (same format as the other services)."""

from __future__ import annotations

import json
import logging
import re
import sys
import threading
import time
from datetime import UTC, datetime

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
    # Route uvicorn's loggers through the JSON handler; probes are not access-logged.
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers[:] = []
        logging.getLogger(name).propagate = True
    logging.getLogger("uvicorn.access").disabled = True
