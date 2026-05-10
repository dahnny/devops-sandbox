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
LOGS_DIR="$ROOT_DIR/logs"
ARCHIVED_LOGS_DIR="$LOGS_DIR/archived"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"

ENV_ID="${1:-}"

if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env-id>"
  echo "Example: $0 env-a1b2c3"
  exit 1
fi

if ! [[ "$ENV_ID" =~ ^env-[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: invalid environment ID '$ENV_ID'."
  echo "Expected format like: env-a1b2c3"
  exit 1
fi

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
ROUTE_FILE="$NGINX_CONF_DIR/$ENV_ID.conf"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: state file not found for environment '$ENV_ID'."
  echo "Expected: $STATE_FILE"
  exit 1
fi

json_get() {
  local key="$1"

  python3 - "$STATE_FILE" "$key" <<'PY'
import json
import sys

path = sys.argv[1]
key = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

value = data.get(key, "")

if value is None:
    print("")
else:
    print(value)
PY
}

CONTAINER_NAME="$(json_get container_name)"
NETWORK_NAME="$(json_get network)"
LOG_PID="$(json_get log_pid)"
LOG_DIR="$(json_get log_dir)"

if [[ -z "$NETWORK_NAME" ]]; then
  NETWORK_NAME="sandbox-net-$ENV_ID"
fi

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$LOGS_DIR/$ENV_ID"
fi

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

reload_nginx() {
  if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER")" == "true" ]]; then
      docker exec "$NGINX_CONTAINER" nginx -t >/dev/null
      docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null
    else
      echo "Warning: Nginx container '$NGINX_CONTAINER' exists but is not running. Skipping reload."
    fi
  else
    echo "Warning: Nginx container '$NGINX_CONTAINER' not found. Skipping reload."
  fi
}

echo "Destroying sandbox environment..."
echo "ID: $ENV_ID"

mkdir -p "$ARCHIVED_LOGS_DIR"

echo "$(timestamp) killing log shipper if running"

if [[ -n "$LOG_PID" ]] && [[ "$LOG_PID" =~ ^[0-9]+$ ]]; then
  kill "$LOG_PID" >/dev/null 2>&1 || true
fi

if [[ -f "$LOG_DIR/log_shipper.pid" ]]; then
  FILE_LOG_PID="$(cat "$LOG_DIR/log_shipper.pid" 2>/dev/null || true)"

  if [[ -n "$FILE_LOG_PID" ]] && [[ "$FILE_LOG_PID" =~ ^[0-9]+$ ]]; then
    kill "$FILE_LOG_PID" >/dev/null 2>&1 || true
  fi
fi

echo "$(timestamp) removing labeled containers"

LABELED_CONTAINERS="$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" || true)"

if [[ -n "$LABELED_CONTAINERS" ]]; then
  docker rm -f $LABELED_CONTAINERS >/dev/null
else
  echo "No labeled containers found for $ENV_ID"
fi

if [[ -n "$CONTAINER_NAME" ]]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

echo "$(timestamp) removing Nginx route"

rm -f "$ROUTE_FILE"

echo "$(timestamp) reloading Nginx"

reload_nginx

echo "$(timestamp) disconnecting Nginx from network"

docker network disconnect "$NETWORK_NAME" "$NGINX_CONTAINER" >/dev/null 2>&1 || true

echo "$(timestamp) removing Docker network"

docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true

echo "$(timestamp) archiving logs"

ARCHIVE_DIR="$ARCHIVED_LOGS_DIR/$ENV_ID"

if [[ -d "$LOG_DIR" ]]; then
  rm -rf "$ARCHIVE_DIR"
  mv "$LOG_DIR" "$ARCHIVE_DIR"
else
  mkdir -p "$ARCHIVE_DIR"
  echo "$(timestamp) no log directory found during destroy" > "$ARCHIVE_DIR/destroy.log"
fi

echo "$(timestamp) deleting state file"

rm -f "$STATE_FILE"

echo
echo "Sandbox environment destroyed successfully."
echo "ID: $ENV_ID"
echo "Archived logs: $ARCHIVE_DIR"