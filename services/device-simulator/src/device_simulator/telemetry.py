"""Virtual sensors that produce plausible telemetry with a bounded random walk."""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import UTC, datetime

SCHEMA_VERSION = 1


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


@dataclass
class VirtualSensor:
    device_id: str
    rng: random.Random
    temperature_c: float = 21.0
    humidity_pct: float = 45.0
    battery_pct: float = 100.0
    seq: int = field(default=0, init=False)

    def next_reading(self, now: datetime | None = None) -> dict:
        """Advance the sensor state and return one telemetry message."""
        now = now or datetime.now(tz=UTC)
        self.seq += 1
        self.temperature_c = _clamp(self.temperature_c + self.rng.gauss(0, 0.3), -20.0, 60.0)
        self.humidity_pct = _clamp(self.humidity_pct + self.rng.gauss(0, 0.8), 0.0, 100.0)
        self.battery_pct = _clamp(self.battery_pct - self.rng.uniform(0.0, 0.05), 0.0, 100.0)
        return {
            "schema_version": SCHEMA_VERSION,
            "device_id": self.device_id,
            "seq": self.seq,
            "ts": now.isoformat(),
            "temperature_c": round(self.temperature_c, 2),
            "humidity_pct": round(self.humidity_pct, 2),
            "battery_pct": round(self.battery_pct, 2),
        }


def make_sensors(count: int, seed: int | None = None) -> list[VirtualSensor]:
    """Create `count` sensors with ids sensor-001..sensor-NNN and varied baselines."""
    rng = random.Random(seed)  # noqa: S311 (simulation, not cryptography)
    sensors = []
    for i in range(1, count + 1):
        sensors.append(
            VirtualSensor(
                device_id=f"sensor-{i:03d}",
                rng=random.Random(rng.random()),  # noqa: S311
                temperature_c=rng.uniform(18.0, 26.0),
                humidity_pct=rng.uniform(30.0, 60.0),
                battery_pct=rng.uniform(70.0, 100.0),
            )
        )
    return sensors


def topic_for(prefix: str, device_id: str) -> str:
    return f"{prefix}/{device_id}/telemetry"
