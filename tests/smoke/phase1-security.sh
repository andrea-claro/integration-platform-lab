#!/usr/bin/env bash
# Phase 1 acceptance (part 2): guardrails.
#   - every domain namespace has default-deny NetworkPolicies, a ResourceQuota and a LimitRange
#   - a pod in "iot" cannot reach a Service in "apps" (no allow rule exists)
#   - workload ServiceAccounts have no Kubernetes API permissions (kubectl auth can-i)
#   - no ServiceAccount outside kube-system is bound to cluster-admin
#   - every Application except the root one runs in its domain AppProject
#
# The network probe starts a short-lived test pod (deleted afterwards): a test
# action, not a deployment, so it does not go through GitOps.
set -euo pipefail

CTX="${KUBE_CONTEXT:-k3d-ipl}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.23.0}"
k() { kubectl --context "$CTX" "$@"; }

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  failures=$((failures + 1))
}

echo "== Phase 1: guardrails"

for ns in platform streaming iot apps observability; do
  missing=()
  k -n "$ns" get networkpolicy default-deny-all >/dev/null 2>&1 || missing+=("default-deny NetworkPolicy")
  k -n "$ns" get resourcequota compute >/dev/null 2>&1 || missing+=("ResourceQuota")
  k -n "$ns" get limitrange container-defaults >/dev/null 2>&1 || missing+=("LimitRange")
  if ((${#missing[@]} == 0)); then
    pass "namespace $ns: default deny, quota, limit range"
  else
    fail "namespace $ns is missing: ${missing[*]}"
  fi
done

# --- Network isolation: iot -> apps must be blocked ----------------------------
# kube-router REJECTs denied traffic, so a blocked connection fails at once with
# "connection refused" (curl exit 7); a plain DROP would time out (exit 28).
# A Service without ready endpoints is refused the same way, so check first
# that the API is actually serving (it also answers through the gateway).
ready_endpoints="$(k -n apps get endpointslices -l kubernetes.io/service-name=telemetry-api \
  -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)"
probe_overrides='{
  "spec": {
    "securityContext": {"runAsNonRoot": true, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "probe",
      "image": "'"$PROBE_IMAGE"'",
      "command": ["sh", "-c", "curl -sS -o /dev/null --max-time 5 http://telemetry-api.apps.svc.cluster.local/healthz; echo curl_exit=$?"],
      "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}}
    }]
  }
}'
k -n iot delete pod netpol-probe --ignore-not-found --wait=true >/dev/null 2>&1
k -n iot run netpol-probe --image="$PROBE_IMAGE" --restart=Never --overrides="$probe_overrides" >/dev/null
# The probe always exits 0 and prints curl's exit code; wait for it to finish.
k -n iot wait pod/netpol-probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1 || true
out="$(k -n iot logs netpol-probe 2>&1 || true)"
k -n iot delete pod netpol-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
code="$(sed -n 's/.*curl_exit=\([0-9]*\).*/\1/p' <<<"$out" | tail -n1)"
case "$code" in
  7 | 28)
    if ((ready_endpoints > 0)); then
      pass "pod in iot cannot reach telemetry-api.apps ($ready_endpoints ready endpoint(s); connection rejected by NetworkPolicy, curl exit $code)"
    else
      fail "telemetry-api.apps has no ready endpoints: the probe cannot tell a policy block from a missing backend"
    fi
    ;;
  0) fail "pod in iot reached telemetry-api.apps: the default-deny policy is not enforced" ;;
  6) fail "probe could not resolve telemetry-api.apps.svc (DNS egress blocked?) - inconclusive" ;;
  *) fail "network probe inconclusive (curl exit '${code:-none}'): $(tail -n 3 <<<"$out" | tr '\n' ' ')" ;;
esac

# --- RBAC: workload ServiceAccounts have no API permissions --------------------
sa="system:serviceaccount:apps:telemetry-api"
for check in "list secrets -n apps" "get pods -n platform" "create deployments -n apps" "get configmaps -n apps"; do
  # shellcheck disable=SC2086 # word splitting of $check is intended
  if [[ "$(k auth can-i --as="$sa" $check 2>/dev/null || true)" == "no" ]]; then
    pass "$sa cannot: $check"
  else
    fail "$sa CAN: $check"
  fi
done

bound="$(k get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name == "cluster-admin") | .subjects[]?
  | select(.kind == "ServiceAccount" and .namespace != "kube-system") | "\(.namespace)/\(.name)"')"
if [[ -z "$bound" ]]; then
  pass "no ServiceAccount outside kube-system is bound to cluster-admin"
else
  fail "ServiceAccounts bound to cluster-admin: $bound"
fi

# --- Argo CD AppProjects ---------------------------------------------------------
in_default="$(k -n argocd get applications.argoproj.io -o json | jq -r '
  .items[] | select(.spec.project == "default" and .metadata.name != "root") | .metadata.name')"
if [[ -z "$in_default" ]]; then
  pass "every Application except root runs in its domain AppProject"
else
  fail "Applications still in the default project: $(tr '\n' ' ' <<<"$in_default")"
fi

if ((failures)); then
  echo "Phase 1 guardrail checks: $failures failure(s)."
  exit 1
fi
echo "Phase 1 guardrail checks passed."
