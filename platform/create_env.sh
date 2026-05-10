#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

APP_IMAGE="${APP_IMAGE:-sandbox-demo-app}"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
BASE_URL="${BASE_URL:-http://localhost}"
DEFAULT_TTL="${DEFAULT_TTL:-1800}"

ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"

ENV_NAME="${1:-}"
TTL="${2:-$DEFAULT_TTL}"

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <environment-name> [ttl-seconds]"
  echo "Example: $0 demo 1800"
  exit 1
fi

if ! [[ "$ENV_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: environment name may only contain letters, numbers, dots, underscores, and hyphens."
  exit 1
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]] || [[ "$TTL" -le 0 ]]; then
  echo "Error: TTL must be a positive number of seconds."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed or not in PATH."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon is not running or your user cannot access Docker."
  exit 1
fi

if ! docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
  echo "Error: Docker image '$APP_IMAGE' not found."
  echo "Build it first with: docker build -t $APP_IMAGE ."
  exit 1
fi

if ! docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
  echo "Error: Nginx container '$NGINX_CONTAINER' does not exist."
  echo "Start it first before creating environments."
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER")" != "true" ]]; then
  echo "Error: Nginx container '$NGINX_CONTAINER' is not running."
  exit 1
fi

mkdir -p "$ENVS_DIR" "$LOGS_DIR" "$NGINX_CONF_DIR"

generate_env_id() {
  local suffix
  suffix="$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
  echo "env-$suffix"
}

while true; do
  ENV_ID="$(generate_env_id)"
  STATE_FILE="$ENVS_DIR/$ENV_ID.json"
  ROUTE_FILE="$NGINX_CONF_DIR/$ENV_ID.conf"
  NETWORK_NAME="sandbox-net-$ENV_ID"
  CONTAINER_NAME="sandbox-app-$ENV_ID"

  if [[ ! -e "$STATE_FILE" ]] \
    && [[ ! -e "$ROUTE_FILE" ]] \
    && ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 \
    && ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    break
  fi
done

LOG_DIR="$LOGS_DIR/$ENV_ID"
APP_LOG="$LOG_DIR/app.log"
LOG_PID_FILE="$LOG_DIR/log_shipper.pid"

CREATED_AT="$(date +%s)"
CREATED_AT_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

CONTAINER_ID=""
LOG_PID=""
STATE_TMP=""
ROUTE_TMP=""

cleanup_on_error() {
  local exit_code=$?
  set +e

  echo "Error: environment creation failed. Rolling back partial resources..."

  if [[ -n "${LOG_PID:-}" ]]; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "${CONTAINER_ID:-}" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  docker network disconnect "$NETWORK_NAME" "$NGINX_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true

  rm -f "$ROUTE_FILE" "$ROUTE_TMP" "$STATE_TMP"

  if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
    docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 \
      && docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap cleanup_on_error ERR INT TERM

echo "Creating sandbox environment..."
echo "Name: $ENV_NAME"
echo "TTL: $TTL seconds"

docker network create "$NETWORK_NAME" >/dev/null

CONTAINER_ID="$(
  docker run -d \
    --name "$CONTAINER_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.name=$ENV_NAME" \
    --network "$NETWORK_NAME" \
    -e "ENV_ID=$ENV_ID" \
    -e "ENV_NAME=$ENV_NAME" \
    "$APP_IMAGE"
)"

docker network connect "$NETWORK_NAME" "$NGINX_CONTAINER"

mkdir -p "$LOG_DIR"

docker logs -f "$CONTAINER_ID" >> "$APP_LOG" 2>&1 &
LOG_PID="$!"
echo "$LOG_PID" > "$LOG_PID_FILE"

ROUTE_TMP="$(mktemp "$NGINX_CONF_DIR/$ENV_ID.conf.tmp.XXXXXX")"

cat > "$ROUTE_TMP" <<EOF
location = /$ENV_ID {
    return 301 /$ENV_ID/;
}

location /$ENV_ID/ {
    proxy_pass http://$CONTAINER_NAME:8080/;

    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Sandbox-Env $ENV_ID;
}
EOF

mv "$ROUTE_TMP" "$ROUTE_FILE"

docker exec "$NGINX_CONTAINER" nginx -t >/dev/null
docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null

STATE_TMP="$(mktemp "$ENVS_DIR/$ENV_ID.json.tmp.XXXXXX")"

cat > "$STATE_TMP" <<EOF
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": $CREATED_AT,
  "created_at_iso": "$CREATED_AT_ISO",
  "ttl": $TTL,
  "status": "running",
  "container_id": "$CONTAINER_ID",
  "container_name": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "app_image": "$APP_IMAGE",
  "url": "$BASE_URL/$ENV_ID/",
  "log_dir": "$LOG_DIR",
  "app_log": "$APP_LOG",
  "log_pid": $LOG_PID,
  "outage_mode": null
}
EOF

mv "$STATE_TMP" "$STATE_FILE"

trap - ERR INT TERM

echo
echo "Sandbox environment created successfully."
echo "ID: $ENV_ID"
echo "Name: $ENV_NAME"
echo "URL: $BASE_URL/$ENV_ID/"
echo "Health: $BASE_URL/$ENV_ID/health"
echo "TTL: $TTL seconds"
echo "Status: running"