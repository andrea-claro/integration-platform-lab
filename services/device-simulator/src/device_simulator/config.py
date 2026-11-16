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
    mqtt_client_id: str = "device-simulator"
    mqtt_topic_prefix: str = "devices"
    mqtt_qos: int = 1
    device_count: int = 5
    publish_interval_seconds: float = 2.0
    seed: int | None = None
    http_port: int = 8080
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> Settings:
        seed = _env("SEED")
        settings = cls(
            mqtt_host=_env("MQTT_HOST", cls.mqtt_host),
            mqtt_port=int(_env("MQTT_PORT", str(cls.mqtt_port))),
            mqtt_username=_env("MQTT_USERNAME"),
            mqtt_password=_env("MQTT_PASSWORD"),
            mqtt_client_id=_env("MQTT_CLIENT_ID", cls.mqtt_client_id),
            mqtt_topic_prefix=_env("MQTT_TOPIC_PREFIX", cls.mqtt_topic_prefix).strip("/"),
            mqtt_qos=int(_env("MQTT_QOS", str(cls.mqtt_qos))),
            device_count=int(_env("DEVICE_COUNT", str(cls.device_count))),
            publish_interval_seconds=float(
                _env("PUBLISH_INTERVAL_SECONDS", str(cls.publish_interval_seconds))
            ),
            seed=int(seed) if seed is not None else None,
            http_port=int(_env("HTTP_PORT", str(cls.http_port))),
            log_level=_env("LOG_LEVEL", cls.log_level),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.device_count < 1:
            raise ValueError("DEVICE_COUNT must be >= 1")
        if self.publish_interval_seconds <= 0:
            raise ValueError("PUBLISH_INTERVAL_SECONDS must be > 0")
        if self.mqtt_qos not in (0, 1, 2):
            raise ValueError("MQTT_QOS must be 0, 1 or 2")
        if (self.mqtt_username is None) != (self.mqtt_password is None):
            raise ValueError("set both MQTT_USERNAME and MQTT_PASSWORD, or neither")
