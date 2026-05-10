#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
ENVS_DIR="$ROOT_DIR/envs"

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_ID="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
      exit 1
      ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

if ! [[ "$ENV_ID" =~ ^env-[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: invalid environment ID '$ENV_ID'."
  exit 1
fi

STATE_FILE="$ENVS_DIR/$ENV_ID.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: state file not found for '$ENV_ID'."
  exit 1
fi

json_get() {
  local key="$1"

  python3 - "$STATE_FILE" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

value = data.get(sys.argv[2], "")
print("" if value is None else value)
PY
}

set_state_value() {
  local key="$1"
  local value="$2"

  python3 - "$STATE_FILE" "$STATE_FILE.tmp" "$key" "$value" <<'PY'
import json
import os
import sys

path, tmp_path, key, value = sys.argv[1:5]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data[key] = None if value == "__NULL__" else value

with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

os.replace(tmp_path, path)
PY
}

CONTAINER_NAME="$(json_get container_name)"
NETWORK_NAME="$(json_get network)"

if [[ -z "$CONTAINER_NAME" || -z "$NETWORK_NAME" ]]; then
  echo "Error: missing container_name or network in state file."
  exit 1
fi

if [[ "$CONTAINER_NAME" == "$NGINX_CONTAINER" ]] || [[ "$CONTAINER_NAME" == *daemon* ]] || [[ "$CONTAINER_NAME" == *cleanup* ]]; then
  echo "Error: refusing to simulate outage against platform container '$CONTAINER_NAME'."
  exit 1
fi

case "$MODE" in
  crash)
    docker kill "$CONTAINER_NAME" >/dev/null
    set_state_value outage_mode crash
    echo "Crashed $ENV_ID by killing $CONTAINER_NAME"
    ;;
  pause)
    docker pause "$CONTAINER_NAME" >/dev/null
    set_state_value outage_mode pause
    echo "Paused $ENV_ID"
    ;;
  network)
    docker network disconnect "$NETWORK_NAME" "$CONTAINER_NAME" >/dev/null
    set_state_value outage_mode network
    echo "Disconnected $ENV_ID from $NETWORK_NAME"
    ;;
  recover)
    docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker unpause "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" >/dev/null 2>&1 || true
    set_state_value outage_mode "__NULL__"
    set_state_value status running
    echo "Recovered $ENV_ID"
    ;;
  stress)
    docker exec -d "$CONTAINER_NAME" sh -c "python - <<'PY'
import time
end = time.time() + 60
while time.time() < end:
    pass
PY" >/dev/null
    set_state_value outage_mode stress
    echo "Started simple CPU stress inside $ENV_ID for about 60 seconds"
    ;;
  *)
    echo "Error: mode must be one of crash, pause, network, recover, stress."
    exit 1
    ;;
esac
