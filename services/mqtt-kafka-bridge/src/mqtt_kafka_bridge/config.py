"""Configuration from environment variables (12-factor)."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name, default)
    return value if value not in ("", None) else default


@dataclass(frozen=True)
class Settings:
    mqtt_host: str = "localhost"
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    # Fixed client id + persistent session + PUBACK only after Kafka accepted the
    # record: at-least-once from the broker to Kafka, including across restarts.
    mqtt_client_id: str = "mqtt-kafka-bridge"
    mqtt_subscribe_topic: str = "devices/+/telemetry"
    mqtt_qos: int = 1
    kafka_bootstrap_servers: str = "localhost:9092"
    kafka_topic: str = "telemetry.raw"
    kafka_dlq_topic: str | None = None
    kafka_health_interval_seconds: float = 15.0
    http_port: int = 8080
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> Settings:
        settings = cls(
            mqtt_host=_env("MQTT_HOST", cls.mqtt_host),
            mqtt_port=int(_env("MQTT_PORT", str(cls.mqtt_port))),
            mqtt_username=_env("MQTT_USERNAME"),
            mqtt_password=_env("MQTT_PASSWORD"),
            mqtt_client_id=_env("MQTT_CLIENT_ID", cls.mqtt_client_id),
            mqtt_subscribe_topic=_env("MQTT_SUBSCRIBE_TOPIC", cls.mqtt_subscribe_topic),
            mqtt_qos=int(_env("MQTT_QOS", str(cls.mqtt_qos))),
            kafka_bootstrap_servers=_env("KAFKA_BOOTSTRAP_SERVERS", cls.kafka_bootstrap_servers),
            kafka_topic=_env("KAFKA_TOPIC", cls.kafka_topic),
            kafka_dlq_topic=_env("KAFKA_DLQ_TOPIC"),
            kafka_health_interval_seconds=float(
                _env("KAFKA_HEALTH_INTERVAL_SECONDS", str(cls.kafka_health_interval_seconds))
            ),
            http_port=int(_env("HTTP_PORT", str(cls.http_port))),
            log_level=_env("LOG_LEVEL", cls.log_level),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.mqtt_qos not in (0, 1, 2):
            raise ValueError("MQTT_QOS must be 0, 1 or 2")
        if (self.mqtt_username is None) != (self.mqtt_password is None):
            raise ValueError("set both MQTT_USERNAME and MQTT_PASSWORD, or neither")
        if not self.kafka_topic:
            raise ValueError("KAFKA_TOPIC must not be empty")

    def producer_config(self) -> dict:
        """librdkafka settings: idempotent producer, bounded retries via delivery timeout."""
        return {
            "bootstrap.servers": self.kafka_bootstrap_servers,
            "client.id": self.mqtt_client_id,
            "enable.idempotence": True,
            "acks": "all",
            "linger.ms": 20,
            "compression.type": "lz4",
            "delivery.timeout.ms": 30000,
            "retry.backoff.ms": 200,
            "retry.backoff.max.ms": 5000,
            "socket.keepalive.enable": True,
        }
