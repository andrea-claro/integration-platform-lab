#!/usr/bin/env bash
# Phase 3 acceptance: observability.
#   - the stack and its configuration are deployed by Argo CD
#   - every scrape target is up (this also proves the NetworkPolicies allow the scrapes)
#   - the five alert rules are loaded and Prometheus is connected to Alertmanager
#   - the pipeline metrics show data flowing; the dashboard is provisioned
# Queries go through the API server's service proxy: no port-forward needed.
#
#   tests/smoke/phase3-observability.sh
set -euo pipefail

CTX="${KUBE_CONTEXT:-k3d-ipl}"
k() { kubectl --context "$CTX" "$@"; }
PROM="/api/v1/namespaces/observability/services/http:kps-prometheus:9090/proxy"

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  failures=$((failures + 1))
}
prom() { k get --raw "$PROM$1" 2>/dev/null; }
# query <promql>: first value of an instant query, or empty.
query() {
  local q
  q="$(jq -rn --arg q "$1" '$q | @uri')"
  prom "/api/v1/query?query=$q" | jq -r '.data.result[0].value[1] // empty'
}

echo "== Phase 3: observability"

for app in kube-prometheus-stack observability-config; do
  state="$(k -n argocd get applications.argoproj.io "$app" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  if [[ "$state" == "Synced/Healthy" ]]; then
    pass "Application $app is Synced/Healthy"
  else
    fail "Application $app is '${state:-missing}'"
  fi
done

targets="$(prom /api/v1/targets?state=active || true)"
if [[ -z "$targets" ]]; then
  fail "Prometheus API not reachable (kubectl -n observability get pods)"
else
  for job in device-simulator mqtt-kafka-bridge telemetry-api; do
    if jq -e --arg j "$job" '[.data.activeTargets[] | select(.labels.job == $j)] | length > 0' <<<"$targets" >/dev/null; then
      pass "target $job is scraped"
    else
      fail "no target for job $job (PodMonitor 'services')"
    fi
  done
  for pool in kafka-exporter cert-manager; do
    if jq -e --arg p "podMonitor/observability/$pool/0" '[.data.activeTargets[] | select(.scrapePool == $p)] | length > 0' <<<"$targets" >/dev/null; then
      pass "target $pool is scraped"
    else
      fail "no target for PodMonitor $pool"
    fi
  done
  down="$(jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.labels.pod // .labels.instance): \(.lastError)"' <<<"$targets")"
  total="$(jq '.data.activeTargets | length' <<<"$targets")"
  if [[ -z "$down" ]]; then
    pass "all $total scrape targets are up"
  else
    fail "targets down (NetworkPolicy or workload): $(tr '\n' ';' <<<"$down")"
  fi
fi

loaded="$(prom /api/v1/rules?type=alert | jq -r '.data.groups[].rules[].name' 2>/dev/null || true)"
for alert in TelemetryPipelineStalled KafkaConsumerLagHigh CertificateExpiringSoon PodCrashLooping TargetDown; do
  if grep -qx "$alert" <<<"$loaded"; then pass "alert rule $alert loaded"; else fail "alert rule $alert not loaded"; fi
done

am="$(prom /api/v1/alertmanagers | jq '.data.activeAlertmanagers | length' 2>/dev/null || echo 0)"
if ((am > 0)); then pass "Prometheus sends alerts to $am Alertmanager(s)"; else fail "no active Alertmanager in Prometheus"; fi

rate="$(query 'sum(rate(bridge_kafka_messages_produced_total[5m]))')"
if [[ -n "$rate" ]] && awk -v r="$rate" 'BEGIN { exit !(r > 0) }'; then
  pass "pipeline metrics: $(printf '%.1f' "$rate") records/s into Kafka"
else
  fail "no records/s into Kafka in the metrics (rate: ${rate:-none})"
fi
lag="$(query 'sum(kafka_consumergroup_lag{consumergroup="telemetry-api"})')"
if [[ -n "$lag" ]]; then pass "Kafka consumer lag is measured (telemetry-api: $lag)"; else fail "no kafka_consumergroup_lag for telemetry-api"; fi
expiry="$(query 'min(certmanager_certificate_expiration_timestamp_seconds{name="gateway-tls"}) - time()')"
if [[ -n "$expiry" ]]; then
  pass "gateway certificate expiry is measured ($(awk -v s="$expiry" 'BEGIN { printf "%d", s / 86400 }') days left)"
else
  fail "no certificate expiry metric for gateway-tls"
fi

firing="$(prom /api/v1/alerts | jq -r '[.data.alerts[] | select(.state == "firing") | .labels.alertname] | unique | join(", ")' 2>/dev/null || true)"
if [[ -z "$firing" ]]; then pass "no alert firing"; else fail "alerts firing: $firing (make alertmanager-ui)"; fi

if k -n observability get configmap -l grafana_dashboard=1 -o name 2>/dev/null | grep -q integration-platform-overview; then
  pass "dashboard 'Integration Platform overview' provisioned for Grafana"
else
  fail "dashboard ConfigMap missing (observability-config)"
fi
grafana="$(k get --raw /api/v1/namespaces/observability/services/http:kps-grafana:80/proxy/api/health 2>/dev/null | jq -r '.database // empty' || true)"
if [[ "$grafana" == "ok" ]]; then pass "Grafana is healthy"; else fail "Grafana health check failed"; fi

if ((failures)); then
  echo "Phase 3 observability checks: $failures failure(s)."
  exit 1
fi
echo "Phase 3 observability checks passed."
