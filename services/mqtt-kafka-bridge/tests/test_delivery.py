"""Acknowledgement logic: PUBACK only after Kafka accepted the record."""

import json
import threading
from types import SimpleNamespace

import pytest
from confluent_kafka import KafkaError

from mqtt_kafka_bridge.config import Settings
from mqtt_kafka_bridge.main import PENDING, Bridge


class FakeClient:
    def __init__(self) -> None:
        self.acks: list[tuple[int, int]] = []

    def ack(self, mid: int, qos: int) -> None:
        self.acks.append((mid, qos))


class FakeProducer:
    def __init__(self) -> None:
        self.produced: list[tuple[str, bytes | None, bytes, object]] = []

    def produce(self, topic, key=None, value=None, on_delivery=None) -> None:
        self.produced.append((topic, key, value, on_delivery))


class FakeMsg:
    def __init__(self, topic: str) -> None:
        self._topic = topic

    def topic(self) -> str:
        return self._topic

    def latency(self) -> float:
        return 0.01


def make_bridge(dlq: str | None = None) -> Bridge:
    bridge = Bridge.__new__(Bridge)  # skip real Kafka/MQTT clients
    bridge.settings = Settings(kafka_dlq_topic=dlq)
    bridge.stop_event = threading.Event()
    bridge.client = FakeClient()
    bridge.producer = FakeProducer()
    return bridge


def mqtt_message(mid: int = 1, qos: int = 1, payload: bytes | None = None):
    payload = (
        payload
        or json.dumps(
            {
                "device_id": "sensor-001",
                "ts": "2026-11-16T12:00:00+00:00",
                "temperature_c": 21.0,
                "humidity_pct": 40.0,
                "battery_pct": 90.0,
            }
        ).encode()
    )
    return SimpleNamespace(topic="devices/sensor-001/telemetry", payload=payload, mid=mid, qos=qos)


def deliver(bridge: Bridge, err: KafkaError | None, index: int = -1) -> None:
    topic, _key, _value, callback = bridge.producer.produced[index]
    callback(err, FakeMsg(topic))


def pending() -> float:
    return PENDING._value.get()


def test_ack_only_after_kafka_delivery():
    bridge = make_bridge()
    before = pending()
    bridge._on_message(None, None, mqtt_message(mid=7))
    assert bridge.client.acks == []
    assert pending() == before + 1
    deliver(bridge, None)
    assert bridge.client.acks == [(7, 1)]
    assert pending() == before


def test_retriable_failure_is_reproduced_not_acked():
    bridge = make_bridge()
    bridge._on_message(None, None, mqtt_message(mid=8))
    deliver(bridge, KafkaError(KafkaError._MSG_TIMED_OUT))
    assert bridge.client.acks == []
    assert len(bridge.producer.produced) == 2
    deliver(bridge, None)  # Kafka is back
    assert bridge.client.acks == [(8, 1)]


def test_permanent_failure_is_dropped_and_acked():
    bridge = make_bridge()
    bridge._on_message(None, None, mqtt_message(mid=9))
    deliver(bridge, KafkaError(KafkaError.MSG_SIZE_TOO_LARGE))
    assert bridge.client.acks == [(9, 1)]
    assert len(bridge.producer.produced) == 1


def test_failure_during_shutdown_leaves_message_for_redelivery():
    bridge = make_bridge()
    bridge._on_message(None, None, mqtt_message(mid=10))
    bridge.stop_event.set()
    deliver(bridge, KafkaError(KafkaError._MSG_TIMED_OUT))
    assert bridge.client.acks == []
    assert len(bridge.producer.produced) == 1


@pytest.mark.parametrize(("dlq", "dlq_records"), [(None, 0), ("telemetry.dlq", 1)])
def test_invalid_message_acked_immediately_and_dead_lettered(dlq, dlq_records):
    bridge = make_bridge(dlq)
    bridge._on_message(None, None, mqtt_message(mid=11, payload=b"not json"))
    assert bridge.client.acks == [(11, 1)]
    assert len(bridge.producer.produced) == dlq_records


def test_qos0_never_acked():
    bridge = make_bridge()
    bridge._on_message(None, None, mqtt_message(mid=0, qos=0))
    deliver(bridge, None)
    assert bridge.client.acks == []
