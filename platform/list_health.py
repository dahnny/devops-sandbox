#!/usr/bin/env python3

import json
import time
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"


def tail(path: Path) -> str:
    if not path.exists():
        return "no health checks yet"

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return lines[-1] if lines else "no health checks yet"


now = int(time.time())
state_files = sorted(ENVS_DIR.glob("*.json"))

if not state_files:
    print("No active environments.")
    raise SystemExit(0)

for state_file in state_files:
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(f"{state_file.name}: invalid state file")
        continue

    env_id = state.get("id", state_file.stem)
    created_at = int(state.get("created_at", now))
    ttl = int(state.get("ttl", 0))
    ttl_remaining = max(0, created_at + ttl - now)
    status = state.get("status", "unknown")
    last_check = tail(LOGS_DIR / env_id / "health.log")

    print(f"{env_id} status={status} ttl_remaining={ttl_remaining}s last_check='{last_check}'")
