import json
import urllib.error
import urllib.request

import pytest

from mqtt_kafka_bridge.observability import HealthServer


@pytest.fixture
def server():
    state = {"ready": False}
    srv = HealthServer(
        0,
        liveness=lambda: (True, {}),
        readiness=lambda: (state["ready"], {"mqtt_connected": state["ready"]}),
    )
    srv.start()
    yield srv, state
    srv.stop()


def get(port: int, path: str) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def test_healthz_ok(server):
    srv, _ = server
    code, body = get(srv.port, "/healthz")
    assert code == 200
    assert json.loads(body)["status"] == "ok"


def test_readyz_follows_state(server):
    srv, state = server
    assert get(srv.port, "/readyz")[0] == 503
    state["ready"] = True
    assert get(srv.port, "/readyz")[0] == 200


def test_metrics_exposed(server):
    srv, _ = server
    code, body = get(srv.port, "/metrics")
    assert code == 200
    assert b"python_info" in body


def test_unknown_path(server):
    srv, _ = server
    assert get(srv.port, "/nope")[0] == 404
