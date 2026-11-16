#!/usr/bin/env bash
# Point every Argo CD Application (and the bootstrap default) at another Git URL.
# Usage: scripts/set-repo-url.sh https://github.com/<owner>/<repo>.git
set -euo pipefail

cd "$(dirname "$0")/.."

new="${1:?usage: $0 <git-url>}"
old="$(sed -n 's/^ *default *= *"\(https:\/\/github.com\/[^"]*\.git\)"$/\1/p' infra/bootstrap/variables.tf | head -n1)"
[[ -n "$old" ]] || { echo "error: current repo URL not found in infra/bootstrap/variables.tf" >&2; exit 1; }
[[ "$old" != "$new" ]] || { echo "already set to $new"; exit 0; }

files=$(grep -rlF "$old" gitops infra/bootstrap/variables.tf .env.example 2>/dev/null || true)
for f in $files; do
  OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$f"
  echo "updated $f"
done
echo "Remember to set GITOPS_REPO_URL=$new in .env too."
