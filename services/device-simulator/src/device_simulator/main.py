"""device-simulator: N virtual sensors publishing JSON telemetry to MQTT."""

from __future__ import annotations

import json
import logging
import signal
import threading
import time

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
from prometheus_client import Counter, Gauge

from .config import Settings
from .observability import HealthServer, configure_logging
from .telemetry import make_sensors, topic_for

log = logging.getLogger("device_simulator")

PUBLISHED = Counter("simulator_messages_published_total", "Messages handed to the MQTT client")
PUBLISH_ERRORS = Counter("simulator_publish_errors_total", "Publish calls that failed")
CONNECTED = Gauge("simulator_mqtt_connected", "1 when connected to the MQTT broker")
DEVICES = Gauge("simulator_devices", "Number of simulated devices")


class Simulator:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.sensors = make_sensors(settings.device_count, settings.seed)
        self.stop_event = threading.Event()
        self.connected = threading.Event()
        self.last_tick = time.monotonic()

        self.client = mqtt.Client(
            callback_api_version=CallbackAPIVersion.VERSION2,
            client_id=settings.mqtt_client_id,
            protocol=mqtt.MQTTv311,
        )
        if settings.mqtt_username:
            self.client.username_pw_set(settings.mqtt_username, settings.mqtt_password)
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect

    # paho callbacks run on the network thread
    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            log.error("mqtt connect refused", extra={"reason": str(reason_code)})
            return
        self.connected.set()
        CONNECTED.set(1)
        log.info("mqtt connected", extra={"host": self.settings.mqtt_host})

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        self.connected.clear()
        CONNECTED.set(0)
        if not self.stop_event.is_set():
            log.warning("mqtt disconnected, reconnecting", extra={"reason": str(reason_code)})

    def liveness(self) -> tuple[bool, dict]:
        # Alive while the publish loop keeps ticking (stuck loop -> restart).
        age = time.monotonic() - self.last_tick
        return age < max(30.0, 5 * self.settings.publish_interval_seconds), {"loop_age_s": round(age, 1)}

    def readiness(self) -> tuple[bool, dict]:
        return self.connected.is_set(), {"mqtt_connected": self.connected.is_set()}

    def run(self) -> None:
        s = self.settings
        DEVICES.set(len(self.sensors))
        self.client.connect_async(s.mqtt_host, s.mqtt_port, keepalive=30)
        self.client.loop_start()
        log.info(
            "simulator started",
            extra={"devices": len(self.sensors), "interval_s": s.publish_interval_seconds},
        )
        try:
            while not self.stop_event.is_set():
                self.last_tick = time.monotonic()
                if self.connected.is_set():
                    self.publish_all()
                self.stop_event.wait(s.publish_interval_seconds)
        finally:
            self.client.disconnect()
            self.client.loop_stop()
            log.info("simulator stopped")

    def publish_all(self) -> None:
        for sensor in self.sensors:
            reading = sensor.next_reading()
            topic = topic_for(self.settings.mqtt_topic_prefix, sensor.device_id)
            info = self.client.publish(topic, json.dumps(reading), qos=self.settings.mqtt_qos)
            if info.rc == mqtt.MQTT_ERR_SUCCESS:
                PUBLISHED.inc()
            else:
                PUBLISH_ERRORS.inc()
                log.warning("publish failed", extra={"topic": topic, "rc": info.rc})


def main() -> None:
    settings = Settings.from_env()
    configure_logging("device-simulator", settings.log_level)
    sim = Simulator(settings)
    health = HealthServer(settings.http_port, sim.liveness, sim.readiness)
    health.start()

    def _shutdown(signum, _frame) -> None:
        log.info("shutdown requested", extra={"signal": signal.Signals(signum).name})
        sim.stop_event.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    try:
        sim.run()
    finally:
        health.stop()
