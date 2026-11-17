#!/usr/bin/env bash
# Incident "dns": the bridge points at a Kafka hostname that does not resolve.
# As if someone had patched it live with the namespace from the Strimzi
# quickstart ("kafka") instead of ours ("streaming"). Live drift: Argo CD
# self-heal is paused first.
#
#   make break-dns      then follow docs/runbooks/incident-dns.md
#   make restore-dns
set -euo pipefail
# shellcheck source=incidents/lib.sh
source "$(dirname "$0")/../lib.sh"

APP=iot-mqtt-kafka-bridge
WRONG="ipl-kafka-bootstrap.kafka.svc.cluster.local:9092"

k -n iot get deployment mqtt-kafka-bridge >/dev/null
date +%s >"$STATE_DIR/ipl-incident-dns.start"

pause_self_heal "$APP"
k -n iot set env deployment/mqtt-kafka-bridge KAFKA_BOOTSTRAP_SERVERS="$WRONG" >/dev/null
log "injected: mqtt-kafka-bridge now uses KAFKA_BOOTSTRAP_SERVERS=$WRONG"

cat <<MSG

What to expect (nothing else is broken):
  - the bridge restarts and stays unready; the simulator keeps publishing and
    Mosquitto queues the messages for the bridge's persistent session
  - the API keeps answering, with readings that get older every minute
  - Argo CD shows $APP OutOfSync (live state differs from Git)
  - alert TelemetryPipelineStalled fires within about 5 minutes

Investigate as if you did not know the cause:
  make status ; make alertmanager-ui ; make grafana-ui
  runbook: docs/runbooks/incident-dns.md

Then: make restore-dns
MSG
