#!/usr/bin/env bash
# Create .env from .env.example and fill self-generated secrets with random values.
# Existing values in .env are never overwritten; external secrets stay CHANGE_ME
# until you paste them in by hand.
set -euo pipefail

cd "$(dirname "$0")/.."

EXAMPLE=.env.example
TARGET=.env
GENERATED=(
  TELEMETRY_API_DEMO_KEY
  TELEMETRY_API_ADMIN_KEY
  GRAFANA_ADMIN_PASSWORD
  MQTT_SIMULATOR_PASSWORD
  MQTT_BRIDGE_PASSWORD
)

umask 077

if [[ ! -f "$TARGET" ]]; then
  cp "$EXAMPLE" "$TARGET"
  echo "created $TARGET from $EXAMPLE"
fi
chmod 600 "$TARGET"

# Add variables that exist in .env.example but are missing from .env.
while IFS= read -r line; do
  [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
  key="${BASH_REMATCH[1]}"
  if ! grep -qE "^${key}=" "$TARGET"; then
    echo "$line" >>"$TARGET"
    echo "added missing variable $key"
  fi
done <"$EXAMPLE"

random_secret() {
  # 32 random bytes, hex encoded: safe in YAML, URLs and HTTP headers.
  openssl rand -hex 32
}

for key in "${GENERATED[@]}"; do
  current="$(grep -E "^${key}=" "$TARGET" | head -n1 | cut -d= -f2-)"
  if [[ -z "$current" || "$current" == "CHANGE_ME" ]]; then
    value="$(random_secret)"
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$TARGET" >"$tmp"
    cat "$tmp" >"$TARGET"
    rm -f "$tmp"
    echo "generated $key"
  fi
done

missing=()
while IFS= read -r line; do
  [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
  key="${BASH_REMATCH[1]}"
  current="$(grep -E "^${key}=" "$TARGET" | head -n1 | cut -d= -f2-)"
  [[ -z "$current" || "$current" == "CHANGE_ME" ]] && missing+=("$key")
done <"$EXAMPLE"

if ((${#missing[@]})); then
  echo
  echo "Still to fill in by hand in $TARGET (see README > Secrets):"
  printf '  - %s\n' "${missing[@]}"
fi
