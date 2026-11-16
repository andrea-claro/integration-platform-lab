#!/usr/bin/env bash
# End-to-end check of the compose stack: simulator -> MQTT -> bridge -> Kafka -> API.
# Usage: scripts/dev-smoke.sh [base-url]   (default http://127.0.0.1:8088)
set -euo pipefail

BASE="${1:-http://127.0.0.1:8088}"
DEADLINE=$((SECONDS + 90))

echo "waiting for readings at $BASE ..."
until body="$(curl -fsS "$BASE/v1/readings/latest?limit=5" 2>/dev/null)" && [[ "$body" != "[]" ]]; do
  if ((SECONDS > DEADLINE)); then
    echo "FAIL: no readings after 90s" >&2
    exit 1
  fi
  sleep 3
done

first="$(curl -fsS "$BASE/v1/readings/latest?limit=1")"
device="$(sed -n 's/.*"device_id":"\([^"]*\)".*/\1/p' <<<"$first")"
sleep 5
second="$(curl -fsS "$BASE/v1/devices/$device/latest")"

echo "latest:  $first"
echo "stats:   $(curl -fsS "$BASE/v1/devices/$device/stats")"
if [[ "$first" == "[$second]" ]]; then
  echo "FAIL: reading for $device did not change in 5s (stream stalled?)" >&2
  exit 1
fi
curl -fsS "$BASE/readyz" >/dev/null && echo "readyz:  ok"
echo "PASS: fresh readings flow end to end"
