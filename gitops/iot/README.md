# iot

MQTT ingestion (PLAN 2.2–2.4). One Argo CD Application per component, project `iot`.

| Folder | Application | What |
|---|---|---|
| `mosquitto/` | `iot-mosquitto` | Eclipse Mosquitto 2.1.2 (official image), `mosquitto.iot.svc:1883`, cluster-internal |
| `device-simulator/` | `iot-device-simulator` | 10 virtual sensors, one JSON reading every 5 s each, to `devices/<id>/telemetry` |
| `mqtt-kafka-bridge/` | `iot-mqtt-kafka-bridge` | `devices/+/telemetry` → Kafka `telemetry.raw` (invalid messages → `telemetry.dlq`) |

**Authentication.** Every client has its own user. The broker's password file and each client's
credentials come from SealedSecrets created by `make seal`. The ACL (`mosquitto/acl`) lets the
simulator only publish and the bridge only subscribe to `devices/+/telemetry`. Mosquitto 2.1 wants
both files owned by the broker user, so an init container copies them from the Secret/ConfigMap
into an in-memory volume as uid 1883, mode 0400.

**Delivery guarantee.** The bridge keeps a persistent MQTT session (fixed client id, QoS 1) and
acknowledges a message only after Kafka accepted it. While Kafka or the bridge is down, the broker
queues the messages (up to 10 000, persisted on a 256 Mi volume), so nothing acknowledged is lost.
That is also why the simulator and the bridge run as a single replica with the `Recreate` strategy.

**Network.** Only the simulator and the bridge can reach the broker, and only the bridge can reach
Kafka (`gitops/platform/guardrails`). Plain MQTT inside the cluster; TLS is a planned hardening step.

Images: `ghcr.io/andrea-claro/ipl-<service>:<version>`, published by CI; the version pinned here
must match `services/<service>/pyproject.toml` (checked by `.github/workflows/images.yaml`).
