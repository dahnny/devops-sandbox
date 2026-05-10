#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
CLEANUP_LOG="$LOGS_DIR/cleanup.log"
INTERVAL="${CLEANUP_INTERVAL:-60}"

mkdir -p "$ENVS_DIR" "$LOGS_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "$(timestamp) $*" | tee -a "$CLEANUP_LOG"
}

get_json_number() {
  local file="$1"
  local key="$2"

  python3 - "$file" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print(int(data.get(sys.argv[2], 0)))
PY
}

log "cleanup daemon started with ${INTERVAL}s interval"

while true; do
  shopt -s nullglob

  for state_file in "$ENVS_DIR"/*.json; do
    env_id="$(basename "$state_file" .json)"

    if ! created_at="$(get_json_number "$state_file" created_at 2>/dev/null)"; then
      log "warning: could not read created_at from $state_file"
      continue
    fi

    if ! ttl="$(get_json_number "$state_file" ttl 2>/dev/null)"; then
      log "warning: could not read ttl from $state_file"
      continue
    fi

    now="$(date +%s)"
    expires_at=$((created_at + ttl))

    if (( now > expires_at )); then
      log "ttl expired for $env_id, destroying environment"

      if "$SCRIPT_DIR/destroy_env.sh" "$env_id" >> "$CLEANUP_LOG" 2>&1; then
        log "destroyed expired environment $env_id"
      else
        log "warning: failed to destroy expired environment $env_id"
      fi
    fi
  done

  sleep "$INTERVAL"
done
