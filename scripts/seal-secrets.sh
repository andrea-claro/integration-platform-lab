#!/usr/bin/env bash
# Turn the secrets in .env into SealedSecret manifests that are safe to commit.
#
# - Plain Secret manifests are never written into the repository: they are
#   generated with `kubectl create secret --dry-run` and piped into kubeseal.
# - Helper files (the Mosquitto password file) live in a private temp dir that
#   is removed on exit.
# - Values equal to CHANGE_ME (or empty) are skipped.
#
# Requires: kubectl, kubeseal, a running Sealed Secrets controller (Phase 1.3)
# and, for the Mosquitto password file, Docker.
#
# Usage: scripts/seal-secrets.sh [secret-name ...]   (default: all)
set -euo pipefail

cd "$(dirname "$0")/.."

SEALED_SECRETS_NS="${SEALED_SECRETS_NS:-platform}"
SEALED_SECRETS_NAME="${SEALED_SECRETS_NAME:-sealed-secrets}"
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-eclipse-mosquitto:2.1.2-alpine}"

[[ -f .env ]] || { echo "error: .env not found, run 'make env' first" >&2; exit 1; }
for bin in kubectl kubeseal; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found in PATH" >&2; exit 1; }
done

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KUBECTL=(kubectl --context "$KUBE_CONTEXT")
else
  KUBECTL=(kubectl)
fi

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

is_set() {
  local value="${!1:-}"
  [[ -n "$value" && "$value" != "CHANGE_ME" ]]
}

# seal <name> <namespace> <output-file> <kubectl create secret generic args...>
seal() {
  local name="$1" namespace="$2" out="$3"
  shift 3
  mkdir -p "$(dirname "$out")"
  "${KUBECTL[@]}" create secret generic "$name" --namespace "$namespace" \
    --dry-run=client -o yaml "$@" \
    | kubeseal --controller-namespace "$SEALED_SECRETS_NS" \
        --controller-name "$SEALED_SECRETS_NAME" \
        --context "${KUBE_CONTEXT:-$(kubectl config current-context)}" \
        --format yaml >"$out"
  echo "sealed $namespace/$name -> $out"
}

skip() { echo "skipped $1: $2 not set in .env"; }

seal_grafana() {
  is_set GRAFANA_ADMIN_PASSWORD || { skip grafana-admin GRAFANA_ADMIN_PASSWORD; return; }
  seal grafana-admin observability gitops/observability/secrets/sealedsecret-grafana-admin.yaml \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"
}

seal_api_keys() {
  is_set TELEMETRY_API_DEMO_KEY || { skip telemetry-api-keys TELEMETRY_API_DEMO_KEY; return; }
  is_set TELEMETRY_API_ADMIN_KEY || { skip telemetry-api-keys TELEMETRY_API_ADMIN_KEY; return; }
  # Envoy Gateway API-key auth: one entry per client id, the value is the key.
  seal telemetry-api-keys apps gitops/apps/telemetry-api/sealedsecret-api-keys.yaml \
    --from-literal=demo="$TELEMETRY_API_DEMO_KEY" \
    --from-literal=admin="$TELEMETRY_API_ADMIN_KEY"
}

seal_mqtt() {
  is_set MQTT_SIMULATOR_PASSWORD || { skip mqtt MQTT_SIMULATOR_PASSWORD; return; }
  is_set MQTT_BRIDGE_PASSWORD || { skip mqtt MQTT_BRIDGE_PASSWORD; return; }
  command -v docker >/dev/null || { echo "error: docker is needed to hash the Mosquitto passwords" >&2; return 1; }

  # Hashed password file for the broker, built inside the official image.
  local passwd="$WORKDIR/passwd"
  # Mode 600: mosquitto_passwd warns about (and will refuse) world-readable files.
  (umask 077 && : >"$passwd")
  docker run --rm -v "$WORKDIR:/work" "$MOSQUITTO_IMAGE" sh -c "
    mosquitto_passwd -b /work/passwd device-simulator '$MQTT_SIMULATOR_PASSWORD' &&
    mosquitto_passwd -b /work/passwd mqtt-kafka-bridge '$MQTT_BRIDGE_PASSWORD'" >/dev/null

  seal mosquitto-passwd iot gitops/iot/mosquitto/sealedsecret-passwd.yaml \
    --from-file=passwd="$passwd"
  seal device-simulator-mqtt iot gitops/iot/device-simulator/sealedsecret-mqtt.yaml \
    --from-literal=MQTT_USERNAME=device-simulator \
    --from-literal=MQTT_PASSWORD="$MQTT_SIMULATOR_PASSWORD"
  seal mqtt-kafka-bridge-mqtt iot gitops/iot/mqtt-kafka-bridge/sealedsecret-mqtt.yaml \
    --from-literal=MQTT_USERNAME=mqtt-kafka-bridge \
    --from-literal=MQTT_PASSWORD="$MQTT_BRIDGE_PASSWORD"
}

ALL=(grafana api_keys mqtt)
targets=("$@")
((${#targets[@]})) || targets=("${ALL[@]}")

"${KUBECTL[@]}" -n "$SEALED_SECRETS_NS" get service "$SEALED_SECRETS_NAME" >/dev/null 2>&1 || {
  echo "error: Sealed Secrets controller not found ($SEALED_SECRETS_NS/$SEALED_SECRETS_NAME)." >&2
  echo "       It is installed by Argo CD in Phase 1.3." >&2
  exit 1
}

for t in "${targets[@]}"; do
  "seal_${t//-/_}"
done

echo
echo "Review the generated files, then commit them: SealedSecrets are safe to push."
