"""Background Kafka consumer that feeds the in-memory store."""

from __future__ import annotations

import json
import logging
import threading
from datetime import UTC, datetime

from confluent_kafka import OFFSET_BEGINNING, Consumer, KafkaError
from prometheus_client import Counter, Gauge, Histogram

from .config import Settings
from .store import TelemetryStore

log = logging.getLogger("telemetry_api.consumer")

CONSUMED = Counter("api_kafka_messages_consumed_total", "Records consumed from Kafka")
INVALID = Counter("api_invalid_messages_total", "Records that could not be applied", ["reason"])
CONSUME_ERRORS = Counter("api_kafka_consume_errors_total", "Consumer errors", ["code"])
KAFKA_UP = Gauge("api_kafka_up", "0 while the consumer reports all brokers down")
DEVICES = Gauge("api_devices", "Devices currently tracked by the API")
E2E_LATENCY = Histogram(
    "api_end_to_end_latency_seconds",
    "Device timestamp to consumption time",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 300),
)


def apply_record(store: TelemetryStore, value: bytes | None, now: datetime | None = None) -> str | None:
    """Parse one record and update the store. Returns an error label, or None on success."""
    if not value:
        return "empty"
    try:
        reading = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "bad_json"
    if not isinstance(reading, dict) or not isinstance(reading.get("device_id"), str):
        return "missing_device_id"
    try:
        ts = datetime.fromisoformat(reading["ts"])
    except (KeyError, TypeError, ValueError):
        return "bad_ts"
    if ts.tzinfo is None:
        return "bad_ts"
    if not store.update(reading):
        return "device_cap"
    now = now or datetime.now(tz=UTC)
    E2E_LATENCY.observe(max(0.0, (now - ts).total_seconds()))
    return None


class TelemetryConsumer(threading.Thread):
    def __init__(self, settings: Settings, store: TelemetryStore) -> None:
        super().__init__(name="kafka-consumer", daemon=True)
        self.settings = settings
        self.store = store
        self.stop_event = threading.Event()
        self.assigned = threading.Event()
        self.kafka_up = False
        self._replayed = False
        self._consumer = Consumer(
            {
                **settings.consumer_config(),
                "error_cb": self._on_error,
                # librdkafka's own log lines go through the JSON handler (served by poll()).
                "logger": logging.getLogger("librdkafka"),
            }
        )

    def _on_error(self, err: KafkaError) -> None:
        CONSUME_ERRORS.labels(err.name()).inc()
        if err.code() == KafkaError._ALL_BROKERS_DOWN:
            self._set_kafka_up(False)
        log.error("kafka client error", extra={"error": str(err), "code": err.name()})

    def _set_kafka_up(self, up: bool) -> None:
        if up != self.kafka_up:
            log.info("kafka availability changed", extra={"kafka_up": up})
        self.kafka_up = up
        KAFKA_UP.set(1 if up else 0)

    def _on_assign(self, consumer: Consumer, partitions) -> None:
        if self.settings.kafka_replay_on_start and not self._replayed:
            for p in partitions:
                p.offset = OFFSET_BEGINNING
            consumer.assign(partitions)
            self._replayed = True
        self.assigned.set()
        self._set_kafka_up(True)
        log.info("partitions assigned", extra={"partitions": [p.partition for p in partitions]})

    def run(self) -> None:
        self._consumer.subscribe([self.settings.kafka_topic], on_assign=self._on_assign)
        log.info(
            "consumer started",
            extra={"topic": self.settings.kafka_topic, "group": self.settings.kafka_group_id},
        )
        try:
            while not self.stop_event.is_set():
                msg = self._consumer.poll(1.0)
                if msg is None:
                    continue
                if msg.error():
                    if msg.error().code() != KafkaError._PARTITION_EOF:
                        CONSUME_ERRORS.labels(msg.error().name()).inc()
                        log.warning("consume error", extra={"error": str(msg.error())})
                    continue
                self._set_kafka_up(True)
                CONSUMED.inc()
                error = apply_record(self.store, msg.value())
                if error:
                    INVALID.labels(error).inc()
                DEVICES.set(self.store.device_count())
        except Exception:
            log.exception("consumer crashed")
            raise
        finally:
            self._consumer.close()  # commits offsets and leaves the group
            log.info("consumer stopped")

    def stop(self, timeout: float = 10.0) -> None:
        self.stop_event.set()
        self.join(timeout)

    def is_live(self) -> bool:
        return self.is_alive()

    def is_ready(self) -> bool:
        # Ready once warm (partitions assigned). If Kafka goes away later we keep
        # serving the last known readings rather than dropping out of the Service.
        return self.is_alive() and self.assigned.is_set()
