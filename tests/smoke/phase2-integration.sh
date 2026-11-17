#!/usr/bin/env bash
# Phase 2 acceptance: integration workloads.
#   - Strimzi, Kafka, topics, Mosquitto, simulator, bridge and API are up (GitOps)
#   - simulator -> MQTT -> Kafka -> API: fresh readings over HTTPS through the Gateway
#   - no key or a wrong key -> 401; a burst above the demo key's limit -> 429
#   - the docs are public; health and metrics endpoints are not routed
#
#   tests/smoke/phase2-integration.sh
set -euo pipefail

CTX="${KUBE_CONTEXT:-k3d-ipl}"
HOST="${API_HOST:-api.ipl.localhost}"
PORT="${GATEWAY_PORT:-8443}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-60}"
BURST="${BURST:-30}"   # demo key limit: 20 requests per minute
k() { kubectl --context "$CTX" "$@"; }

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  failures=$((failures + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== Phase 2: integration workloads"

# --- GitOps state ------------------------------------------------------------------
for app in strimzi streaming-kafka iot-mosquitto iot-device-simulator iot-mqtt-kafka-bridge apps-telemetry-api; do
  state="$(k -n argocd get applications.argoproj.io "$app" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  if [[ "$state" == "Synced/Healthy" ]]; then
    pass "Application $app is Synced/Healthy"
  else
    fail "Application $app is '${state:-missing}' (argocd app get $app, or the Argo CD UI)"
  fi
done

ready() { # ready <namespace> <resource>
  [[ "$(k -n "$1" get "$2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}
for r in kafka/ipl kafkatopic/telemetry-raw kafkatopic/telemetry-dlq; do
  if ready streaming "$r"; then pass "streaming/$r is Ready"; else fail "streaming/$r is not Ready (kubectl -n streaming describe $r)"; fi
done

for d in iot/mosquitto iot/device-simulator iot/mqtt-kafka-bridge apps/telemetry-api; do
  available="$(k -n "${d%%/*}" get deployment "${d#*/}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ "${available:-0}" -ge 1 ]]; then
    pass "deployment $d is available"
  else
    fail "deployment $d has no available replica (kubectl -n ${d%%/*} describe deployment ${d#*/})"
  fi
done

accepted() { # accepted <kind> <name>: Envoy Gateway accepted the policy for its target
  [[ "$(k -n apps get "$1" "$2" \
    -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == *True* ]]
}
for p in securitypolicy/telemetry-api-key backendtrafficpolicy/telemetry-api-rate-limit; do
  if accepted "${p%%/*}" "${p#*/}"; then pass "$p accepted by Envoy Gateway"; else fail "$p not accepted (kubectl -n apps describe $p)"; fi
done

# --- Through the Gateway -------------------------------------------------------------
k -n platform get secret internal-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$TMP/ca.crt"
[[ -s "$TMP/ca.crt" ]] || {
  fail "could not read the internal root CA (secret platform/internal-root-ca)"
  exit 1
}
# Keys from the Secret that Sealed Secrets decrypted (the source of truth in the cluster).
key() { k -n apps get secret telemetry-api-keys -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d; }
DEMO_KEY="$(key demo)"
ADMIN_KEY="$(key admin)"
[[ -n "$DEMO_KEY" && -n "$ADMIN_KEY" ]] || {
  fail "could not read the API keys (secret apps/telemetry-api-keys)"
  exit 1
}

# status <path> [curl args...]: HTTP status of an HTTPS request through the Gateway.
status() {
  local path="$1"
  shift
  curl -sS -o "$TMP/body" -w '%{http_code}' --max-time 10 --cacert "$TMP/ca.crt" \
    --resolve "$HOST:$PORT:127.0.0.1" "$@" "https://$HOST:$PORT$path" 2>/dev/null || true # 000 = no response
}

code="$(status /v1/readings/latest)"
if [[ "$code" == "401" ]]; then pass "no API key -> 401"; else fail "no API key -> $code (expected 401)"; fi

code="$(status /v1/readings/latest -H "x-api-key: not-a-valid-key")"
if [[ "$code" == "401" ]]; then pass "wrong API key -> 401"; else fail "wrong API key -> $code (expected 401)"; fi

# Fresh data with the admin key, so the demo bucket is left for the burst below.
code="$(status /v1/readings/latest -H "x-api-key: $ADMIN_KEY")"
if [[ "$code" == "200" ]]; then
  # Age in seconds of the newest reading (timestamps like 2026-11-17T21:26:53.123456Z or +00:00).
  age="$(jq -r '[.[].ts | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601] | if length == 0 then "none" else (now - max | floor) end' "$TMP/body" 2>/dev/null || echo "invalid")"
  devices="$(jq -r 'length' "$TMP/body" 2>/dev/null || echo 0)"
  if [[ "$age" =~ ^-?[0-9]+$ ]] && ((age <= MAX_AGE_SECONDS)); then
    pass "fresh readings over HTTPS: $devices device(s), newest ${age}s old (simulator -> MQTT -> Kafka -> API)"
  else
    fail "readings are not fresh (newest: $age s, devices: $devices); check the bridge: kubectl -n iot logs deploy/mqtt-kafka-bridge"
  fi
else
  fail "admin key -> $code (expected 200): $(head -c 200 "$TMP/body" 2>/dev/null)"
fi

for path in /docs /openapi.json; do
  code="$(status "$path")"
  if [[ "$code" == "200" ]]; then pass "$path is public -> 200"; else fail "$path -> $code (expected 200)"; fi
done

for path in /metrics /healthz; do
  code="$(status "$path" -H "x-api-key: $ADMIN_KEY")"
  if [[ "$code" == "404" ]]; then pass "$path is not routed -> 404"; else fail "$path -> $code (expected 404: not routed)"; fi
done

# --- Rate limit: burst with the published demo key ---------------------------------
ok=0
limited=0
other=""
for _ in $(seq "$BURST"); do
  code="$(status /v1/devices -H "x-api-key: $DEMO_KEY")"
  case "$code" in
    200) ok=$((ok + 1)) ;;
    429) limited=$((limited + 1)) ;;
    *) other="$other $code" ;;
  esac
done
if ((limited > 0)) && [[ -z "$other" ]]; then
  pass "burst of $BURST with the demo key: $ok x 200, $limited x 429"
else
  fail "burst of $BURST with the demo key: $ok x 200, $limited x 429, other:${other:- none} (expected some 429)"
fi
# The admin key has its own, larger budget: it is not throttled by the demo burst.
code="$(status /v1/devices -H "x-api-key: $ADMIN_KEY")"
if [[ "$code" == "200" ]]; then pass "admin key unaffected by the demo burst -> 200"; else fail "admin key after the demo burst -> $code (expected 200)"; fi

if ((failures)); then
  echo "Phase 2 integration checks: $failures failure(s)."
  exit 1
fi
echo "Phase 2 integration checks passed."
