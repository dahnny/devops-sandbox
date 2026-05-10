#!/usr/bin/env python3

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
INTERVAL = int(os.getenv("HEALTH_INTERVAL", "30"))


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_state(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_state(path: Path, state: dict) -> None:
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp_path.replace(path)


def poll_health(url: str) -> tuple[int, float]:
    start = time.perf_counter()

    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            status = response.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception:
        status = 0

    latency_ms = (time.perf_counter() - start) * 1000
    return status, latency_ms


def main() -> None:
    ENVS_DIR.mkdir(exist_ok=True)
    LOGS_DIR.mkdir(exist_ok=True)
    failures: dict[str, int] = {}

    print(f"{timestamp()} health poller started with {INTERVAL}s interval", flush=True)

    while True:
        for state_file in sorted(ENVS_DIR.glob("*.json")):
            state = read_state(state_file)

            if not state:
                continue

            env_id = state.get("id", state_file.stem)
            health_url = state.get("url", "").rstrip("/") + "/health"
            log_dir = LOGS_DIR / env_id
            log_dir.mkdir(parents=True, exist_ok=True)

            status, latency_ms = poll_health(health_url)
            ok = 200 <= status < 400
            failures[env_id] = 0 if ok else failures.get(env_id, 0) + 1

            with (log_dir / "health.log").open("a", encoding="utf-8") as f:
                f.write(f"{timestamp()} status={status} latency_ms={latency_ms:.2f}\n")

            new_status = "degraded" if failures[env_id] >= 3 else "running"

            if state.get("status") != new_status:
                state["status"] = new_status
                write_state(state_file, state)

            if failures[env_id] == 3:
                print(f"{timestamp()} warning: {env_id} is degraded", flush=True)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
