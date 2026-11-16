import json
from datetime import UTC, datetime

import pytest

from mqtt_kafka_bridge.config import Settings
from mqtt_kafka_bridge.transform import InvalidMessageError, device_id_from_topic, to_kafka_record

NOW = datetime(2026, 11, 16, 12, 0, 0, tzinfo=UTC)
TOPIC = "devices/sensor-001/telemetry"


def reading(**overrides) -> bytes:
    base = {
        "schema_version": 1,
        "device_id": "sensor-001",
        "seq": 7,
        "ts": "2026-11-16T11:59:59+00:00",
        "temperature_c": 21.5,
        "humidity_pct": 44.0,
        "battery_pct": 97,
    }
    base.update(overrides)
    return json.dumps(base).encode()


def test_valid_message_is_enriched_and_keyed_by_device():
    record = to_kafka_record(TOPIC, reading(), now=NOW)
    assert record.key == b"sensor-001"
    value = json.loads(record.value)
    assert value["temperature_c"] == 21.5
    assert value["ingested_at"] == NOW.isoformat()
    assert value["source_topic"] == TOPIC


@pytest.mark.parametrize(
    ("topic", "payload", "reason"),
    [
        ("devices/sensor-001/status", reading(), "bad_topic"),
        ("devices//telemetry", reading(), "bad_topic"),
        (TOPIC, b"{not json", "bad_json"),
        (TOPIC, b"\xff\xfe", "bad_json"),
        (TOPIC, b"[1, 2]", "bad_json"),
        (TOPIC, reading(device_id="sensor-002"), "device_mismatch"),
        (TOPIC, reading(ts="yesterday"), "bad_ts"),
        (TOPIC, reading(ts="2026-11-16T12:00:00"), "bad_ts"),
        (TOPIC, reading(temperature_c="hot"), "bad_field"),
        (TOPIC, reading(humidity_pct=None), "bad_field"),
        (TOPIC, reading(battery_pct=True), "bad_field"),
        (TOPIC, b'{"x": "' + b"a" * 20000 + b'"}', "too_large"),
    ],
)
def test_invalid_messages_are_rejected_with_reason(topic, payload, reason):
    with pytest.raises(InvalidMessageError) as exc:
        to_kafka_record(topic, payload, now=NOW)
    assert exc.value.reason == reason


def test_nan_is_rejected():
    payload = reading().replace(b"21.5", b"NaN")
    with pytest.raises(InvalidMessageError) as exc:
        to_kafka_record(TOPIC, payload, now=NOW)
    assert exc.value.reason == "bad_field"


def test_device_id_from_topic():
    assert device_id_from_topic("devices/abc/telemetry") == "abc"


def test_producer_config_is_idempotent(monkeypatch):
    monkeypatch.setenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
    cfg = Settings.from_env().producer_config()
    assert cfg["bootstrap.servers"] == "kafka:9092"
    assert cfg["enable.idempotence"] is True
    assert cfg["acks"] == "all"


def test_settings_require_user_and_password_together(monkeypatch):
    monkeypatch.setenv("MQTT_PASSWORD", "x")
    with pytest.raises(ValueError):
        Settings.from_env()
