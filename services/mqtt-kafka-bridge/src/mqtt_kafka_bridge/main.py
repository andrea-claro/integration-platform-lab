"""mqtt-kafka-bridge: MQTT `devices/+/telemetry` -> Kafka `telemetry.raw`."""

from __future__ import annotations

import functools
import logging
import signal
import threading
import time

import paho.mqtt.client as mqtt
from confluent_kafka import KafkaError, KafkaException, Producer
from paho.mqtt.enums import CallbackAPIVersion
from prometheus_client import Counter, Gauge, Histogram

from .config import Settings
from .observability import HealthServer, configure_logging
from .transform import InvalidMessageError, to_kafka_record

log = logging.getLogger("mqtt_kafka_bridge")

RECEIVED = Counter("bridge_mqtt_messages_received_total", "MQTT messages received")
PRODUCED = Counter("bridge_kafka_messages_produced_total", "Records acknowledged by Kafka")
PRODUCE_ERRORS = Counter("bridge_kafka_produce_errors_total", "Failed delivery attempts", ["reason"])
RETRIED = Counter("bridge_kafka_delivery_retries_total", "Records re-produced after a retriable failure")
DROPPED = Counter(
    "bridge_messages_dropped_total", "Messages acknowledged to MQTT without reaching Kafka", ["reason"]
)
INVALID = Counter("bridge_invalid_messages_total", "MQTT messages rejected by validation", ["reason"])
PENDING = Gauge("bridge_pending_messages", "MQTT messages not yet acknowledged (waiting for Kafka)")
MQTT_CONNECTED = Gauge("bridge_mqtt_connected", "1 when connected to the MQTT broker")
KAFKA_UP = Gauge("bridge_kafka_up", "1 when the Kafka cluster answered the last metadata request")
DELIVERY_LATENCY = Histogram(
    "bridge_kafka_delivery_latency_seconds",
    "Time from produce() to broker acknowledgement",
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30),
)

# Delivery failures worth retrying: Kafka unreachable or slow, not a bad record.
RETRIABLE_CODES = {
    KafkaError._MSG_TIMED_OUT,
    KafkaError._TIMED_OUT,
    KafkaError._TRANSPORT,
    KafkaError._ALL_BROKERS_DOWN,
    KafkaError.REQUEST_TIMED_OUT,
    KafkaError.NOT_ENOUGH_REPLICAS,
    KafkaError.LEADER_NOT_AVAILABLE,
    KafkaError.NOT_LEADER_FOR_PARTITION,
}


def is_retriable(err: KafkaError) -> bool:
    return not err.fatal() and (err.retriable() or err.code() in RETRIABLE_CODES)


class Bridge:
    """At-least-once MQTT -> Kafka.

    An MQTT QoS 1 message is acknowledged (PUBACK) only after Kafka has accepted the
    record. While Kafka is down, unacknowledged messages fill the broker's in-flight
    window for this client, so the broker queues the rest: back-pressure instead of
    silent loss. Messages still pending at shutdown are redelivered by the broker
    when the bridge reconnects (persistent session, fixed client id).
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.stop_event = threading.Event()
        self.mqtt_connected = threading.Event()
        self.kafka_ok = False
        self.last_tick = time.monotonic()

        self.producer = Producer(
            {
                **settings.producer_config(),
                "error_cb": self._on_kafka_error,
                # librdkafka's own log lines go through the JSON handler (served by poll()).
                "logger": logging.getLogger("librdkafka"),
            }
        )

        self.client = mqtt.Client(
            callback_api_version=CallbackAPIVersion.VERSION2,
            client_id=settings.mqtt_client_id,
            protocol=mqtt.MQTTv311,
            clean_session=False,
            manual_ack=True,
        )
        if settings.mqtt_username:
            self.client.username_pw_set(settings.mqtt_username, settings.mqtt_password)
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

    # --- MQTT (network thread) -------------------------------------------------
    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            log.error("mqtt connect refused", extra={"reason": str(reason_code)})
            return
        client.subscribe(self.settings.mqtt_subscribe_topic, qos=self.settings.mqtt_qos)
        self.mqtt_connected.set()
        MQTT_CONNECTED.set(1)
        log.info(
            "mqtt connected",
            extra={"host": self.settings.mqtt_host, "topic": self.settings.mqtt_subscribe_topic},
        )

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        self.mqtt_connected.clear()
        MQTT_CONNECTED.set(0)
        if not self.stop_event.is_set():
            log.warning("mqtt disconnected, reconnecting", extra={"reason": str(reason_code)})

    def _on_message(self, client, userdata, message) -> None:
        RECEIVED.inc()
        try:
            record = to_kafka_record(message.topic, message.payload)
        except InvalidMessageError as exc:
            INVALID.labels(exc.reason).inc()
            log.warning("invalid message", extra={"topic": message.topic, "reason": str(exc)})
            if self.settings.kafka_dlq_topic:
                self._produce(self.settings.kafka_dlq_topic, None, message.payload, self._on_dlq_delivery)
            self._ack(message.mid, message.qos)
            return

        PENDING.inc()
        on_delivery = functools.partial(
            self._on_delivery, mid=message.mid, qos=message.qos, key=record.key, value=record.value
        )
        if not self._produce(self.settings.kafka_topic, record.key, record.value, on_delivery):
            self._drop(message.mid, message.qos, "produce_rejected")

    def _ack(self, mid: int, qos: int) -> None:
        if qos > 0:
            self.client.ack(mid, qos)

    def _drop(self, mid: int, qos: int, reason: str) -> None:
        DROPPED.labels(reason).inc()
        PENDING.dec()
        self._ack(mid, qos)

    # --- Kafka ---------------------------------------------------------------------
    def _produce(self, topic: str, key: bytes | None, value: bytes, on_delivery) -> bool:
        """Hand a record to librdkafka. Returns False if it could not be queued."""
        for attempt in (1, 2):
            try:
                self.producer.produce(topic, key=key, value=value, on_delivery=on_delivery)
                return True
            except BufferError:
                # Local queue full: serve delivery callbacks, then try once more.
                self.producer.poll(1.0)
                if attempt == 2:
                    PRODUCE_ERRORS.labels("queue_full").inc()
                    log.error("producer queue full", extra={"topic": topic})
            except KafkaException as exc:
                PRODUCE_ERRORS.labels("produce_call").inc()
                log.error("produce failed", extra={"topic": topic, "error": str(exc)})
                return False
        return False

    def _on_delivery(self, err, msg, *, mid: int, qos: int, key: bytes, value: bytes) -> None:
        if err is None:
            PRODUCED.inc()
            PENDING.dec()
            latency = msg.latency()
            if latency is not None:
                DELIVERY_LATENCY.observe(latency)
            self._ack(mid, qos)
            return

        PRODUCE_ERRORS.labels(err.name()).inc()
        if self.stop_event.is_set():
            return  # not acknowledged: the broker redelivers it after restart
        if is_retriable(err):
            RETRIED.inc()
            log.warning("delivery failed, retrying", extra={"topic": msg.topic(), "error": str(err)})
            on_delivery = functools.partial(self._on_delivery, mid=mid, qos=qos, key=key, value=value)
            if self._produce(msg.topic(), key, value, on_delivery):
                return
        log.error("delivery failed permanently, dropping", extra={"topic": msg.topic(), "error": str(err)})
        self._drop(mid, qos, err.name())

    def _on_dlq_delivery(self, err, msg) -> None:
        if err is not None:
            PRODUCE_ERRORS.labels(err.name()).inc()
            log.error("dead-letter delivery failed", extra={"error": str(err)})

    def _on_kafka_error(self, err: KafkaError) -> None:
        # Transport errors (e.g. DNS resolution of the bootstrap host) surface here.
        log.error(
            "kafka client error",
            extra={"error": str(err), "code": err.name(), "fatal": err.fatal()},
        )

    def check_kafka(self) -> None:
        try:
            self.producer.list_topics(topic=self.settings.kafka_topic, timeout=5)
            ok = True
        except KafkaException as exc:
            ok = False
            log.error("kafka metadata request failed", extra={"error": str(exc)})
        if ok != self.kafka_ok:
            log.info("kafka availability changed", extra={"kafka_up": ok})
        self.kafka_ok = ok
        KAFKA_UP.set(1 if ok else 0)

    # --- Health ----------------------------------------------------------------------
    def liveness(self) -> tuple[bool, dict]:
        age = time.monotonic() - self.last_tick
        return age < 60, {"loop_age_s": round(age, 1)}

    def readiness(self) -> tuple[bool, dict]:
        mqtt_ok = self.mqtt_connected.is_set()
        return mqtt_ok and self.kafka_ok, {"mqtt_connected": mqtt_ok, "kafka_up": self.kafka_ok}

    # --- Main loop -------------------------------------------------------------------
    def run(self) -> None:
        s = self.settings
        self.check_kafka()
        self.client.connect_async(s.mqtt_host, s.mqtt_port, keepalive=30)
        self.client.loop_start()
        log.info("bridge started", extra={"kafka": s.kafka_bootstrap_servers, "topic": s.kafka_topic})
        next_check = time.monotonic() + s.kafka_health_interval_seconds
        try:
            while not self.stop_event.is_set():
                self.last_tick = time.monotonic()
                self.producer.poll(0.5)  # serve delivery callbacks
                if time.monotonic() >= next_check:
                    self.check_kafka()
                    next_check = time.monotonic() + s.kafka_health_interval_seconds
        finally:
            # Stop taking new messages, drain in-flight records while still connected
            # (so their PUBACKs go out), then disconnect. Anything left unacknowledged
            # is redelivered by the broker on the next start.
            self.client.unsubscribe(s.mqtt_subscribe_topic)
            remaining = self.producer.flush(10)
            self.client.disconnect()
            self.client.loop_stop()
            log.info("bridge stopped", extra={"undelivered": remaining})


def main() -> None:
    settings = Settings.from_env()
    configure_logging("mqtt-kafka-bridge", settings.log_level)
    bridge = Bridge(settings)
    health = HealthServer(settings.http_port, bridge.liveness, bridge.readiness)
    health.start()

    def _shutdown(signum, _frame) -> None:
        log.info("shutdown requested", extra={"signal": signal.Signals(signum).name})
        bridge.stop_event.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    try:
        bridge.run()
    finally:
        health.stop()
