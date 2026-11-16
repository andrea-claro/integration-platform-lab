import json
import logging

from device_simulator.observability import DedupFilter, JsonFormatter


def record(msg: str, level: int = logging.ERROR, **extra) -> logging.LogRecord:
    rec = logging.makeLogRecord({"name": "test", "levelno": level, "levelname": "X", "msg": msg})
    for k, v in extra.items():
        setattr(rec, k, v)
    return rec


def test_json_formatter_merges_extra_fields():
    out = json.loads(JsonFormatter("svc").format(record("hello", topic="t1")))
    assert out["service"] == "svc"
    assert out["msg"] == "hello"
    assert out["topic"] == "t1"


def test_dedup_collapses_repeats_and_reports_count():
    f = DedupFilter(window_seconds=0.2)
    assert f.filter(record("connect to 10.0.0.1:9092 failed after 0ms"))
    assert not f.filter(record("connect to 10.0.0.1:9092 failed after 3ms"))  # digits ignored
    assert not f.filter(record("connect to 10.0.0.1:9092 failed after 7ms"))
    import time

    time.sleep(0.25)
    later = record("connect to 10.0.0.1:9092 failed after 1ms")
    assert f.filter(later)
    assert later.suppressed == 2


def test_dedup_never_drops_info():
    f = DedupFilter()
    assert all(f.filter(record("tick", level=logging.INFO)) for _ in range(5))
