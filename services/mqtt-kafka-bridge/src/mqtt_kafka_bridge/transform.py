"""Validate MQTT telemetry and turn it into a Kafka record (pure functions, unit tested)."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from datetime import UTC, datetime

REQUIRED_NUMBERS = ("temperature_c", "humidity_pct", "battery_pct")
MAX_PAYLOAD_BYTES = 16 * 1024


class InvalidMessageError(ValueError):
    """The MQTT message cannot be forwarded; `reason` is a short label for metrics."""

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


@dataclass(frozen=True)
class KafkaRecord:
    key: bytes
    value: bytes
    device_id: str


def device_id_from_topic(topic: str) -> str:
    """devices/<device_id>/telemetry -> <device_id>"""
    parts = topic.split("/")
    if len(parts) != 3 or parts[2] != "telemetry" or not parts[1]:
        raise InvalidMessageError("bad_topic", topic)
    return parts[1]


def _parse_ts(value: object) -> datetime:
    if not isinstance(value, str):
        raise InvalidMessageError("bad_ts", repr(value))
    try:
        ts = datetime.fromisoformat(value)
    except ValueError as exc:
        raise InvalidMessageError("bad_ts", value) from exc
    if ts.tzinfo is None:
        raise InvalidMessageError("bad_ts", "timestamp without timezone")
    return ts


def to_kafka_record(topic: str, payload: bytes, now: datetime | None = None) -> KafkaRecord:
    """Validate one MQTT message and build the Kafka record (key = device id).

    The value is the original reading plus `ingested_at` and `source_topic`, so
    consumers can measure end-to-end latency and trace the origin.
    """
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise InvalidMessageError("too_large", f"{len(payload)} bytes")
    device_id = device_id_from_topic(topic)
    try:
        reading = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidMessageError("bad_json", str(exc)) from exc
    if not isinstance(reading, dict):
        raise InvalidMessageError("bad_json", "payload is not an object")

    if reading.get("device_id") != device_id:
        raise InvalidMessageError("device_mismatch", f"{reading.get('device_id')!r} != {device_id!r}")
    _parse_ts(reading.get("ts"))
    for name in REQUIRED_NUMBERS:
        value = reading.get(name)
        if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
            raise InvalidMessageError("bad_field", name)

    now = now or datetime.now(tz=UTC)
    enriched = {**reading, "ingested_at": now.isoformat(), "source_topic": topic}
    return KafkaRecord(
        key=device_id.encode(),
        value=json.dumps(enriched, separators=(",", ":")).encode(),
        device_id=device_id,
    )
