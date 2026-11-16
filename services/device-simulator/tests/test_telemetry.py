import itertools
from datetime import UTC, datetime

import pytest

from device_simulator.config import Settings
from device_simulator.telemetry import make_sensors, topic_for


def test_make_sensors_ids_and_count():
    sensors = make_sensors(3, seed=1)
    assert [s.device_id for s in sensors] == ["sensor-001", "sensor-002", "sensor-003"]


def test_same_seed_gives_same_readings():
    now = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
    a = [s.next_reading(now) for s in make_sensors(2, seed=42)]
    b = [s.next_reading(now) for s in make_sensors(2, seed=42)]
    assert a == b


def test_reading_schema_and_bounds():
    sensor = make_sensors(1, seed=7)[0]
    readings = [sensor.next_reading() for _ in range(2000)]
    last = readings[-1]
    assert set(last) == {
        "schema_version",
        "device_id",
        "seq",
        "ts",
        "temperature_c",
        "humidity_pct",
        "battery_pct",
    }
    assert last["seq"] == 2000
    assert all(-20.0 <= r["temperature_c"] <= 60.0 for r in readings)
    assert all(0.0 <= r["humidity_pct"] <= 100.0 for r in readings)
    # battery only goes down
    assert all(a["battery_pct"] >= b["battery_pct"] for a, b in itertools.pairwise(readings))
    datetime.fromisoformat(last["ts"])  # valid ISO 8601


def test_topic_for():
    assert topic_for("devices", "sensor-001") == "devices/sensor-001/telemetry"


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("DEVICE_COUNT", "10")
    monkeypatch.setenv("PUBLISH_INTERVAL_SECONDS", "0.5")
    monkeypatch.setenv("MQTT_TOPIC_PREFIX", "/plant-a/")
    s = Settings.from_env()
    assert s.device_count == 10
    assert s.publish_interval_seconds == 0.5
    assert s.mqtt_topic_prefix == "plant-a"


@pytest.mark.parametrize(
    "env",
    [
        {"DEVICE_COUNT": "0"},
        {"PUBLISH_INTERVAL_SECONDS": "0"},
        {"MQTT_QOS": "3"},
        {"MQTT_USERNAME": "only-user"},
    ],
)
def test_settings_validation(monkeypatch, env):
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    with pytest.raises(ValueError):
        Settings.from_env()
