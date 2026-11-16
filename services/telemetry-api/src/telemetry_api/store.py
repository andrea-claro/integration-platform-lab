"""Thread-safe in-memory view: latest reading and running stats per device."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import datetime

METRICS = ("temperature_c", "humidity_pct", "battery_pct")


@dataclass
class RunningStat:
    count: int = 0
    total: float = 0.0
    minimum: float | None = None
    maximum: float | None = None

    def add(self, value: float) -> None:
        self.count += 1
        self.total += value
        self.minimum = value if self.minimum is None else min(self.minimum, value)
        self.maximum = value if self.maximum is None else max(self.maximum, value)

    def as_dict(self) -> dict:
        avg = round(self.total / self.count, 3) if self.count else None
        return {"min": self.minimum, "max": self.maximum, "avg": avg}


@dataclass
class DeviceState:
    device_id: str
    latest: dict
    first_seen: datetime
    last_seen: datetime
    readings: int = 0
    stats: dict[str, RunningStat] = field(default_factory=lambda: {m: RunningStat() for m in METRICS})


class TelemetryStore:
    def __init__(self, max_devices: int = 10_000) -> None:
        self._lock = threading.Lock()
        self._devices: dict[str, DeviceState] = {}
        self.max_devices = max_devices
        self.rejected_devices = 0

    def update(self, reading: dict) -> bool:
        """Apply one reading; returns False when it was dropped (device cap reached)."""
        device_id = reading["device_id"]
        ts = datetime.fromisoformat(reading["ts"])
        with self._lock:
            state = self._devices.get(device_id)
            if state is None:
                if len(self._devices) >= self.max_devices:
                    self.rejected_devices += 1
                    return False
                state = DeviceState(device_id, reading, first_seen=ts, last_seen=ts)
                self._devices[device_id] = state
            state.readings += 1
            for metric in METRICS:
                value = reading.get(metric)
                if isinstance(value, int | float) and not isinstance(value, bool):
                    state.stats[metric].add(float(value))
            # Out-of-order messages update stats but never replace a newer "latest".
            if ts >= state.last_seen:
                state.latest = reading
                state.last_seen = ts
            state.first_seen = min(state.first_seen, ts)
            return True

    def device_count(self) -> int:
        with self._lock:
            return len(self._devices)

    def devices(self) -> list[dict]:
        with self._lock:
            return [
                {"device_id": s.device_id, "last_seen": s.last_seen, "readings": s.readings}
                for s in sorted(self._devices.values(), key=lambda s: s.device_id)
            ]

    def latest(self, device_id: str) -> dict | None:
        with self._lock:
            state = self._devices.get(device_id)
            return dict(state.latest) if state else None

    def latest_all(self, limit: int) -> list[dict]:
        with self._lock:
            states = sorted(self._devices.values(), key=lambda s: s.last_seen, reverse=True)
            return [dict(s.latest) for s in states[:limit]]

    def stats(self, device_id: str) -> dict | None:
        with self._lock:
            state = self._devices.get(device_id)
            if state is None:
                return None
            return {
                "device_id": device_id,
                "readings": state.readings,
                "first_seen": state.first_seen,
                "last_seen": state.last_seen,
                **{metric: stat.as_dict() for metric, stat in state.stats.items()},
            }
