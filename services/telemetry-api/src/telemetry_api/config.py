"""Configuration from environment variables (12-factor)."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name, default)
    return value if value not in ("", None) else default


def _bool(value: str | None) -> bool:
    return str(value).lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Settings:
    kafka_bootstrap_servers: str = "localhost:9092"
    kafka_topic: str = "telemetry.raw"
    kafka_group_id: str = "telemetry-api"
    # The store is in memory: on start, re-read what the topic still retains so the
    # API is warm immediately. Offsets are still committed, so consumer lag stays
    # visible to Kafka Exporter.
    kafka_replay_on_start: bool = True
    max_devices: int = 10_000
    ready_timeout_seconds: float = 60.0
    http_port: int = 8080
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            kafka_bootstrap_servers=_env("KAFKA_BOOTSTRAP_SERVERS", cls.kafka_bootstrap_servers),
            kafka_topic=_env("KAFKA_TOPIC", cls.kafka_topic),
            kafka_group_id=_env("KAFKA_GROUP_ID", cls.kafka_group_id),
            kafka_replay_on_start=_bool(_env("KAFKA_REPLAY_ON_START", str(cls.kafka_replay_on_start))),
            max_devices=int(_env("MAX_DEVICES", str(cls.max_devices))),
            ready_timeout_seconds=float(_env("READY_TIMEOUT_SECONDS", str(cls.ready_timeout_seconds))),
            http_port=int(_env("HTTP_PORT", str(cls.http_port))),
            log_level=_env("LOG_LEVEL", cls.log_level),
        )

    def consumer_config(self) -> dict:
        return {
            "bootstrap.servers": self.kafka_bootstrap_servers,
            "group.id": self.kafka_group_id,
            "client.id": self.kafka_group_id,
            "auto.offset.reset": "earliest",
            "enable.auto.commit": True,
            "auto.commit.interval.ms": 5000,
            # Rejoin quickly after a broker restart (broker minimum is 6s).
            "session.timeout.ms": 10000,
            "heartbeat.interval.ms": 3000,
            "socket.keepalive.enable": True,
        }
