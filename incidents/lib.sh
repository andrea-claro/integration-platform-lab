#!/usr/bin/env bash
# Helpers shared by the incident scenarios (sourced, not executed).
#
# Live-drift scenarios change a resource that Argo CD manages. Self-heal would
# undo the change within seconds, so it is paused first: on the child
# Application and on "root" (which would otherwise restore the child's
# syncPolicy from Git). Restoring means resuming self-heal: Argo CD then puts
# the Git state back. Nothing is fixed by hand.

CTX="${KUBE_CONTEXT:-k3d-ipl}"
k() { kubectl --context "$CTX" "$@"; }

PROM="/api/v1/namespaces/observability/services/http:kps-prometheus:9090/proxy"
# shellcheck disable=SC2034 # used by the scenario scripts
STATE_DIR="${TMPDIR:-/tmp}"

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# self_heal <application> <true|false>
self_heal() {
  k -n argocd patch applications.argoproj.io "$1" --type merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":$2}}}}" >/dev/null
}

pause_self_heal() { # pause_self_heal <application>
  self_heal root false
  self_heal "$1" false
  log "Argo CD self-heal paused for root and $1"
}

resume_self_heal() { # resume_self_heal <application>
  self_heal root true
  # root restores the child's syncPolicy from Git; set it too, in case root is slow.
  self_heal "$1" true
  k -n argocd annotate applications.argoproj.io root "$1" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  log "Argo CD self-heal resumed for root and $1 (hard refresh requested)"
}

# prom_query <promql> [time]: first value of an instant query, or empty.
prom_query() {
  local q t=""
  q="$(jq -rn --arg q "$1" '$q | @uri')"
  [[ -n "${2:-}" ]] && t="&time=$2"
  k get --raw "$PROM/api/v1/query?query=$q$t" 2>/dev/null | jq -r '.data.result[0].value[1] // empty'
}

# first_firing <alertname> <since-epoch>: epoch when the alert first fired, or empty.
first_firing() {
  local q
  q="$(jq -rn --arg q "ALERTS{alertname=\"$1\",alertstate=\"firing\"}" '$q | @uri')"
  k get --raw "$PROM/api/v1/query_range?query=$q&start=$2&end=$(date +%s)&step=15" 2>/dev/null \
    | jq -r '[.data.result[].values[][0]] | min // empty'
}

mmss() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
