#!/usr/bin/env bash
# `make status`: Argo CD applications, pods that are not ready, firing alerts.
set -uo pipefail

CTX="${KUBE_CONTEXT:-k3d-ipl}"
k() { kubectl --context "$CTX" "$@"; }

if ! k version --request-timeout=5s >/dev/null 2>&1; then
  echo "cluster $CTX not reachable: 'k3d cluster start ipl' if it was stopped, 'make cluster' if it does not exist"
  exit 1
fi

echo "== Argo CD applications"
if k get crd applications.argoproj.io >/dev/null 2>&1; then
  k -n argocd get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
else
  echo "(Argo CD not installed: run 'make bootstrap')"
fi

echo
echo "== Pods not ready"
k get pods -A --no-headers 2>/dev/null | awk '
  { split($3, r, "/") }
  $4 == "Completed" || $4 == "Succeeded" { next }
  r[1] != r[2] || $4 != "Running" { print; bad++ }
  END { if (!bad) print "(none)" }'

echo
echo "== Firing alerts"
if k -n observability get service alertmanager-operated >/dev/null 2>&1; then
  k get --raw "/api/v1/namespaces/observability/services/alertmanager-operated:9093/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false" \
    | jq -r 'if length == 0 then "(none)" else .[] | "\(.labels.severity // "-")\t\(.labels.alertname)\t\(.labels.namespace // "")\t\(.annotations.summary // "")" end'
else
  echo "(Alertmanager not installed yet: Phase 3)"
fi
