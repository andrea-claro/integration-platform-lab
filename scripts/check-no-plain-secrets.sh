#!/usr/bin/env bash
# Fail if the repository contains anything that looks like a committed secret:
#   - plain `kind: Secret` manifests (only SealedSecrets are allowed in Git)
#   - .env files other than .env.example
#   - Sealed Secrets controller key backups
# Used by `make lint`, the pre-commit hook and CI.
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

# Prefer the list of files Git would commit; fall back to a filesystem walk.
# (Written for the bash 3.2 that ships with macOS: no mapfile.)
list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard
  else
    find . -type f -not -path './.git/*' -not -path '*/.terraform/*' -not -name '.env' \
      | sed 's|^\./||'
  fi
}

count=0
while IFS= read -r f; do
  count=$((count + 1))
  [[ -f "$f" ]] || continue
  case "$f" in
    *.yaml | *.yml)
      # A YAML document whose top-level kind is exactly "Secret".
      if grep -qE '^kind:[[:space:]]*["'"'"']?Secret["'"'"']?[[:space:]]*$' "$f"; then
        echo "plain Secret manifest: $f (use 'make seal' to create a SealedSecret)"
        status=1
      fi
      if grep -qE 'sealedsecrets\.bitnami\.com/sealed-secrets-key' "$f"; then
        echo "Sealed Secrets controller key backup: $f"
        status=1
      fi
      ;;
  esac
  case "$(basename "$f")" in
    .env.example) ;;
    .env | .env.*)
      echo "env file tracked by Git: $f"
      status=1
      ;;
  esac
done < <(list_files)

if ((status == 0)); then
  echo "check-no-plain-secrets: OK ($count files scanned)"
fi
exit "$status"
