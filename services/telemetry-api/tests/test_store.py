import json
from datetime import UTC, datetime

from telemetry_api.consumer import apply_record
from telemetry_api.store import TelemetryStore


def reading(device="sensor-001", ts="2026-11-16T12:00:00+00:00", temp=20.0, seq=1) -> dict:
    return {
        "device_id": device,
        "seq": seq,
        "ts": ts,
        "temperature_c": temp,
        "humidity_pct": 40.0,
        "battery_pct": 90.0,
    }


def test_latest_and_running_stats():
    store = TelemetryStore()
    store.update(reading(temp=20.0, ts="2026-11-16T12:00:00+00:00", seq=1))
    store.update(reading(temp=24.0, ts="2026-11-16T12:00:02+00:00", seq=2))
    assert store.latest("sensor-001")["seq"] == 2
    stats = store.stats("sensor-001")
    assert stats["readings"] == 2
    assert stats["temperature_c"] == {"min": 20.0, "max": 24.0, "avg": 22.0}


def test_out_of_order_reading_does_not_replace_latest():
    store = TelemetryStore()
    store.update(reading(ts="2026-11-16T12:00:05+00:00", seq=5))
    store.update(reading(ts="2026-11-16T12:00:01+00:00", seq=1, temp=30.0))
    assert store.latest("sensor-001")["seq"] == 5
    stats = store.stats("sensor-001")
    assert stats["readings"] == 2
    assert stats["first_seen"] == datetime(2026, 11, 16, 12, 0, 1, tzinfo=UTC)
    assert stats["temperature_c"]["max"] == 30.0


def test_device_cap():
    store = TelemetryStore(max_devices=1)
    assert store.update(reading(device="a"))
    assert not store.update(reading(device="b"))
    assert store.update(reading(device="a", seq=2))
    assert store.device_count() == 1
    assert store.rejected_devices == 1


def test_latest_all_sorted_and_limited():
    store = TelemetryStore()
    store.update(reading(device="a", ts="2026-11-16T12:00:01+00:00"))
    store.update(reading(device="b", ts="2026-11-16T12:00:03+00:00"))
    store.update(reading(device="c", ts="2026-11-16T12:00:02+00:00"))
    assert [r["device_id"] for r in store.latest_all(2)] == ["b", "c"]


def test_unknown_device():
    store = TelemetryStore()
    assert store.latest("nope") is None
    assert store.stats("nope") is None


def test_apply_record_happy_path_and_errors():
    store = TelemetryStore()
    now = datetime(2026, 11, 16, 12, 0, 1, tzinfo=UTC)
    assert apply_record(store, json.dumps(reading()).encode(), now=now) is None
    assert apply_record(store, None) == "empty"
    assert apply_record(store, b"{broken") == "bad_json"
    assert apply_record(store, b'{"ts": "2026-11-16T12:00:00+00:00"}') == "missing_device_id"
    assert apply_record(store, b'{"device_id": "x", "ts": "soon"}') == "bad_ts"
    assert apply_record(store, b'{"device_id": "x", "ts": "2026-11-16T12:00:00"}') == "bad_ts"
    assert store.device_count() == 1
