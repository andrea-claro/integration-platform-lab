#!/usr/bin/env bash
# Back up / restore the Sealed Secrets controller key pair.
#
# Every SealedSecret in Git is encrypted for this key. A new cluster generates a
# new key, so without a backup all committed SealedSecrets would have to be
# re-sealed after `make down && make cluster`.
#
#   scripts/seal-key.sh backup    # cluster -> secrets/sealed-secrets-key.backup.yaml
#   scripts/seal-key.sh restore   # file -> cluster (run by `make bootstrap`,
#                                 # before Argo CD starts the controller)
#
# The backup is a private key: it stays in secrets/ (gitignored, mode 600) and
# must never be committed. scripts/check-no-plain-secrets.sh fails if it is.
set -euo pipefail

cd "$(dirname "$0")/.."

NS="${SEALED_SECRETS_NS:-platform}"
FILE="${SEALED_SECRETS_KEY_FILE:-secrets/sealed-secrets-key.backup.yaml}"
LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"
CTX="${KUBE_CONTEXT:-k3d-ipl}"
k() { kubectl --context "$CTX" "$@"; }

backup() {
  local keys
  keys="$(k -n "$NS" get secret -l "$LABEL" -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$keys" == "0" ]]; then
    echo "error: no Sealed Secrets key found in namespace $NS (is the controller running?)" >&2
    exit 1
  fi
  umask 077
  mkdir -p "$(dirname "$FILE")"
  # Keep only what is needed to re-create the secrets in a fresh cluster.
  k -n "$NS" get secret -l "$LABEL" -o json \
    | jq '{apiVersion: "v1", kind: "List", items: [.items[] | {
            apiVersion, kind, type, data,
            metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels}
          }]}' >"$FILE"
  chmod 600 "$FILE"
  echo "backed up $keys key(s) to $FILE (keep it private, never commit it)"
}

restore() {
  if [[ ! -f "$FILE" ]]; then
    echo "no Sealed Secrets key backup ($FILE): the controller will generate a new key"
    return 0
  fi
  # The namespace is normally created by Argo CD (platform-base); create it early
  # so the key exists before the controller starts. Argo CD adopts it later.
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f "$FILE" >/dev/null
  echo "restored Sealed Secrets key(s) from $FILE into namespace $NS"
}

case "${1:-}" in
  backup) backup ;;
  restore) restore ;;
  *)
    echo "usage: $0 backup|restore" >&2
    exit 2
    ;;
esac
