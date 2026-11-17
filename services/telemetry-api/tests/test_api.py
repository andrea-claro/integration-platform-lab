import pytest
from fastapi.testclient import TestClient

from telemetry_api.app import create_app
from telemetry_api.store import TelemetryStore


class FakeConsumer:
    def __init__(self) -> None:
        self.kafka_up = True
        self.started = False
        self.stopped = False
        self.live = True
        self.ready = False

    def start(self) -> None:
        self.started = True

    def stop(self, timeout: float = 10.0) -> None:
        self.stopped = True

    def is_live(self) -> bool:
        return self.live

    def is_ready(self) -> bool:
        return self.ready


@pytest.fixture
def store():
    s = TelemetryStore()
    for seq, (device, ts, temp) in enumerate(
        [
            ("sensor-001", "2026-11-16T12:00:00+00:00", 20.0),
            ("sensor-001", "2026-11-16T12:00:02+00:00", 22.0),
            ("sensor-002", "2026-11-16T12:00:01+00:00", 25.0),
        ],
        start=1,
    ):
        s.update(
            {
                "device_id": device,
                "seq": seq,
                "ts": ts,
                "temperature_c": temp,
                "humidity_pct": 40.0,
                "battery_pct": 90.0,
                "ingested_at": ts,
                "source_topic": f"devices/{device}/telemetry",
            }
        )
    return s


@pytest.fixture
def consumer():
    return FakeConsumer()


@pytest.fixture
def client(store, consumer):
    with TestClient(create_app(store, consumer)) as c:
        yield c


def test_lifespan_starts_and_stops_consumer(store, consumer):
    with TestClient(create_app(store, consumer)):
        assert consumer.started
    assert consumer.stopped


def test_list_devices(client):
    r = client.get("/v1/devices")
    assert r.status_code == 200
    assert [d["device_id"] for d in r.json()] == ["sensor-001", "sensor-002"]
    assert r.json()[0]["readings"] == 2


def test_device_latest_hides_internal_fields(client):
    r = client.get("/v1/devices/sensor-001/latest")
    assert r.status_code == 200
    body = r.json()
    assert body["temperature_c"] == 22.0
    assert "source_topic" not in body


def test_device_stats(client):
    r = client.get("/v1/devices/sensor-001/stats")
    assert r.status_code == 200
    assert r.json()["temperature_c"] == {"min": 20.0, "max": 22.0, "avg": 21.0}


def test_latest_readings_limit(client):
    r = client.get("/v1/readings/latest", params={"limit": 1})
    assert r.status_code == 200
    assert [x["device_id"] for x in r.json()] == ["sensor-001"]
    assert client.get("/v1/readings/latest", params={"limit": 0}).status_code == 422


@pytest.mark.parametrize("path", ["/v1/devices/unknown/latest", "/v1/devices/unknown/stats"])
def test_unknown_device_404(client, path):
    assert client.get(path).status_code == 404


def test_invalid_device_id_rejected(client):
    assert client.get("/v1/devices/" + "x" * 65 + "/latest").status_code == 422


def test_health_and_readiness(client, consumer):
    assert client.get("/healthz").status_code == 200
    r = client.get("/readyz")
    assert r.status_code == 503
    consumer.ready = True
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "kafka_up": True, "devices": 2}
    consumer.live = False
    assert client.get("/healthz").status_code == 503


def test_metrics_and_openapi(client):
    client.get("/v1/devices")
    metrics = client.get("/metrics").text
    assert 'api_http_requests_total{method="GET",route="/v1/devices",status="200"}' in metrics
    spec = client.get("/openapi.json").json()
    assert "/v1/devices/{device_id}/stats" in spec["paths"]
    assert "/metrics" not in spec["paths"]


def test_root_redirects_to_docs(client):
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 307
    assert r.headers["location"] == "/docs"


def test_openapi_declares_gateway_api_key(client):
    # The key is enforced by Envoy Gateway; the spec only documents it so that
    # /docs offers "Authorize" and sends the header.
    spec = client.get("/openapi.json").json()
    assert spec["components"]["securitySchemes"]["ApiKey"] == {
        "type": "apiKey",
        "in": "header",
        "name": "x-api-key",
        "description": spec["components"]["securitySchemes"]["ApiKey"]["description"],
    }
    for path, item in spec["paths"].items():
        expected = [{"ApiKey": []}] if path.startswith("/v1/") else None
        assert item["get"].get("security") == expected, path


def test_service_does_not_enforce_the_key(client):
    assert client.get("/v1/devices").status_code == 200
