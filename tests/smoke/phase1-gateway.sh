#!/usr/bin/env bash
# Phase 1 acceptance (part 1): a routed service answers over HTTPS through the
# Gateway, with a certificate issued by the internal CA. Phase 1 used a temporary
# echo service; since Phase 2 the public docs route of the telemetry API.
#
#   tests/smoke/phase1-gateway.sh
set -euo pipefail

CTX="${KUBE_CONTEXT:-k3d-ipl}"
HOST="${API_HOST:-api.ipl.localhost}"
PORT="${GATEWAY_PORT:-8443}"
k() { kubectl --context "$CTX" "$@"; }

pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  exit 1
}

# condition_true <kind> <name> <namespace|""> <condition type>
condition_true() {
  local ns_args=()
  [[ -n "$3" ]] && ns_args=(-n "$3")
  # ${arr[@]+...}: an empty array is "unbound" under set -u in macOS bash 3.2.
  [[ "$(k ${ns_args[@]+"${ns_args[@]}"} get "$1" "$2" \
    -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null)" == "True" ]]
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== Phase 1: gateway + internal CA"

if condition_true clusterissuer internal-ca "" Ready; then
  pass "ClusterIssuer internal-ca is Ready"
else
  fail "ClusterIssuer internal-ca is not Ready (kubectl describe clusterissuer internal-ca)"
fi

if condition_true certificate gateway-tls platform Ready; then
  pass "Certificate platform/gateway-tls is Ready"
else
  fail "Certificate platform/gateway-tls is not Ready (kubectl -n platform describe certificate gateway-tls)"
fi

if condition_true gateway public platform Programmed; then
  pass "Gateway platform/public is Programmed"
else
  fail "Gateway platform/public is not Programmed (kubectl -n platform describe gateway public)"
fi

# Trust only the internal root CA, so a wrong or self-signed certificate fails.
k -n platform get secret internal-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$TMP/ca.crt"
[[ -s "$TMP/ca.crt" ]] || fail "could not read the internal root CA (secret platform/internal-root-ca)"

if ! body="$(curl -sS --fail --max-time 10 --cacert "$TMP/ca.crt" \
  --resolve "$HOST:$PORT:127.0.0.1" "https://$HOST:$PORT/openapi.json")"; then
  fail "HTTPS request to https://$HOST:$PORT/openapi.json failed"
fi
if grep -q '"openapi"' <<<"$body"; then
  pass "telemetry-api answered over HTTPS via the gateway (TLS verified against the internal CA)"
else
  fail "unexpected response: $(head -c 200 <<<"$body")"
fi

issuer="$(openssl s_client -connect "127.0.0.1:$PORT" -servername "$HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null || true)"
if [[ "$issuer" == *"internal root CA"* ]]; then
  pass "certificate $issuer"
else
  fail "unexpected certificate issuer: ${issuer:-<none>}"
fi

echo "Phase 1 gateway checks passed."
