#!/usr/bin/env bash
# promtool unit tests for every alert (PLAN 3.5).
#
# The rules live in PrometheusRule manifests (gitops/observability/rules); promtool
# wants plain rule files, so each manifest's .spec is extracted into a temp dir
# next to a copy of the tests. Test files name their rule file after the manifest:
#   gitops/observability/rules/<name>.yaml -> <name>.rules.yaml
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for manifest in gitops/observability/rules/*.yaml; do
  name="$(basename "$manifest" .yaml)"
  python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["kind"] == "PrometheusRule", sys.argv[1]
yaml.safe_dump(doc["spec"], open(sys.argv[2], "w"), sort_keys=False)
' "$manifest" "$WORK/$name.rules.yaml"
done
cp tests/promtool/*.test.yaml "$WORK/"

promtool check rules "$WORK"/*.rules.yaml
promtool test rules "$WORK"/*.test.yaml

# Every alert must have a runbook (CLAUDE.md conventions).
missing=0
for alert in $(python3 -c '
import glob, yaml
for f in glob.glob("gitops/observability/rules/*.yaml"):
    for g in yaml.safe_load(open(f))["spec"]["groups"]:
        for r in g["rules"]:
            if "alert" in r:
                print(r["alert"])
'); do
  if [[ ! -f "docs/runbooks/$alert.md" ]]; then
    echo "missing runbook: docs/runbooks/$alert.md"
    missing=1
  fi
done
exit "$missing"
