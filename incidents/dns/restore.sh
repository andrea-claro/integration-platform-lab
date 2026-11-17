#!/usr/bin/env bash
# Restore the "dns" incident through GitOps: resume self-heal, let Argo CD put
# the Git value back, then measure detection and recovery and check that the
# messages queued during the outage reached Kafka.
set -euo pipefail
# shellcheck source=incidents/lib.sh
source "$(dirname "$0")/../lib.sh"

APP=iot-mqtt-kafka-bridge
start="$(cat "$STATE_DIR/ipl-incident-dns.start" 2>/dev/null || true)"
restore_at="$(date +%s)"

resume_self_heal "$APP"

log "waiting for Argo CD to restore the Git value of KAFKA_BOOTSTRAP_SERVERS"
for _ in $(seq 60); do
  value="$(k -n iot get deployment mqtt-kafka-bridge \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_BOOTSTRAP_SERVERS")].value}')"
  [[ "$value" == ipl-kafka-bootstrap.streaming.* ]] && break
  sleep 5
done
log "deployment spec back to $value"
k -n iot rollout status deployment/mqtt-kafka-bridge --timeout=180s >/dev/null
log "bridge ready again"

log "waiting for the bridge to drain the MQTT queue"
for _ in $(seq 60); do
  pending="$(prom_query 'sum(bridge_pending_messages)')"
  rate="$(prom_query 'sum(rate(bridge_kafka_messages_produced_total[1m]))')"
  if [[ "${pending:-1}" == "0" ]] && awk -v r="${rate:-0}" 'BEGIN { exit !(r > 0) }'; then break; fi
  sleep 5
done
recovered_at="$(date +%s)"
log "pipeline flowing (pending: ${pending:-?}, $(printf '%.1f' "${rate:-0}") records/s)"

if [[ -z "$start" ]]; then
  echo "(no injection timestamp found: summary skipped)"
  exit 0
fi

window=$((recovered_at - start + 60))
published="$(prom_query "sum(increase(simulator_messages_published_total[${window}s]))")"
delivered="$(prom_query "sum(increase(bridge_kafka_messages_produced_total[${window}s]))")"
fired="$(first_firing TelemetryPipelineStalled "$start")"

echo
echo "== Incident dns: summary (use it for the postmortem)"
echo "  injected            $(date -r "$start" +%H:%M:%S 2>/dev/null || date -d "@$start" +%H:%M:%S)"
if [[ -n "$fired" ]]; then
  echo "  alert fired         +$(mmss $((${fired%.*} - start)))  (TelemetryPipelineStalled)"
else
  echo "  alert fired         not yet (restored before the alert's 'for' window elapsed)"
fi
echo "  restore started     +$(mmss $((restore_at - start)))"
echo "  pipeline recovered  +$(mmss $((recovered_at - start)))"
printf '  messages            published %.0f, delivered to Kafka %.0f (increase() estimates;\n' "${published:-0}" "${delivered:-0}"
echo "                      delivered >= published means nothing was lost)"
rm -f "$STATE_DIR/ipl-incident-dns.start"
