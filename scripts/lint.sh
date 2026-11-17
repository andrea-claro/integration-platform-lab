#!/usr/bin/env bash
# Repository-wide checks. Runs inside the toolbox image (`make lint`) or with
# locally installed tools (`make lint LINT_IN_DOCKER=0`).
set -euo pipefail

cd "$(dirname "$0")/.."

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35.0}"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

step() { printf '\n==> %s\n' "$*"; }

step "secrets: no plain Secret manifests or env files"
scripts/check-no-plain-secrets.sh

step "yamllint"
yamllint --strict -c .yamllint.yaml .

step "shellcheck"
shellcheck scripts/*.sh tests/smoke/*.sh
shellcheck -x incidents/lib.sh incidents/*/*.sh

step "ruff (services)"
ruff check services
ruff format --check services

step "kustomize build + kubeconform (gitops)"
find gitops -name kustomization.yaml -print0 | sort -z | while IFS= read -r -d '' k; do
  dir="$(dirname "$k")"
  echo "--- $dir"
  kustomize build "$dir" | kubeconform -strict -summary \
    -kubernetes-version "$KUBERNETES_VERSION" \
    -schema-location default -schema-location "$CRD_SCHEMAS"
done

step "promtool: alert rule unit tests and runbooks"
scripts/test-rules.sh

step "tofu fmt + validate (infra/bootstrap)"
tofu fmt -check -recursive infra
tofu -chdir=infra/bootstrap init -backend=false -input=false >/dev/null
tofu -chdir=infra/bootstrap validate

printf '\nAll checks passed.\n'
