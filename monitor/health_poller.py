#!/usr/bin/env python3

import json
import os
import sys
import time
import tempfile
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone


ROOT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"

DEFAULT_INTERVAL_SECONDS = 30
FAILURE_THRESHOLD = 3


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_dotenv() -> None:
    env_file = ROOT_DIR / ".env"

    if not env_file.exists():
        return

    for line in env_file.read_text().splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        os.environ.setdefault(key, value)


def read_json(path: Path) -> dict | None:
    try:
        with path.open("r", encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        print(f"[WARN] Invalid JSON in {path}: {exc}", flush=True)
        return None


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        delete=False,
    ) as temp_file:
        json.dump(data, temp_file, indent=2)
        temp_file.write("\n")
        temp_name = temp_file.name

    os.replace(temp_name, path)


def build_health_url(env: dict) -> str:
    base_url = env.get("url")

    if base_url:
        return base_url.rstrip("/") + "/health"

    platform_base_url = os.getenv("BASE_URL", "http://localhost").rstrip("/")
    env_id = env["id"]

    return f"{platform_base_url}/{env_id}/health"


def check_health(url: str, timeout_seconds: int = 5) -> tuple[int, float, str]:
    start_time = time.perf_counter()

    try:
        request = urllib.request.Request(url, method="GET")

        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            status_code = response.getcode()
            response.read()

        latency_ms = (time.perf_counter() - start_time) * 1000
        return status_code, latency_ms, "ok"

    except urllib.error.HTTPError as exc:
        latency_ms = (time.perf_counter() - start_time) * 1000
        return exc.code, latency_ms, f"http_error:{exc.code}"

    except Exception as exc:
        latency_ms = (time.perf_counter() - start_time) * 1000
        return 0, latency_ms, f"error:{type(exc).__name__}"


def append_health_log(env_id: str, log_dir: Path, status_code: int, latency_ms: float, result: str) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    health_log = log_dir / "health.log"

    line = (
        f"{utc_now_iso()} "
        f"env={env_id} "
        f"status={status_code} "
        f"latency_ms={latency_ms:.2f} "
        f"result={result}\n"
    )

    with health_log.open("a", encoding="utf-8") as file:
        file.write(line)


def update_env_status(state_file: Path, desired_status: str) -> None:
    env = read_json(state_file)

    if env is None:
        return

    current_status = env.get("status")

    if current_status == desired_status:
        return

    env["status"] = desired_status
    env["last_status_change_at"] = utc_now_iso()

    atomic_write_json(state_file, env)


def get_active_state_files() -> list[Path]:
    if not ENVS_DIR.exists():
        return []

    return sorted(ENVS_DIR.glob("*.json"))


def poll_once(failure_counts: dict[str, int]) -> None:
    state_files = get_active_state_files()

    if not state_files:
        print(f"[{utc_now_iso()}] No active environments found.", flush=True)
        return

    for state_file in state_files:
        env = read_json(state_file)

        if env is None:
            continue

        env_id = env.get("id")

        if not env_id:
            print(f"[WARN] State file {state_file} has no id. Skipping.", flush=True)
            continue

        health_url = build_health_url(env)

        log_dir_value = env.get("log_dir")
        log_dir = Path(log_dir_value) if log_dir_value else LOGS_DIR / env_id

        status_code, latency_ms, result = check_health(health_url)

        append_health_log(
            env_id=env_id,
            log_dir=log_dir,
            status_code=status_code,
            latency_ms=latency_ms,
            result=result,
        )

        healthy = 200 <= status_code < 300

        if healthy:
            failure_counts[env_id] = 0
            update_env_status(state_file, "running")

            print(
                f"[{utc_now_iso()}] {env_id} healthy "
                f"status={status_code} latency_ms={latency_ms:.2f}",
                flush=True,
            )

        else:
            failure_counts[env_id] = failure_counts.get(env_id, 0) + 1

            print(
                f"[{utc_now_iso()}] {env_id} health check failed "
                f"status={status_code} failures={failure_counts[env_id]}",
                flush=True,
            )

            if failure_counts[env_id] >= FAILURE_THRESHOLD:
                update_env_status(state_file, "degraded")

                print(
                    f"[WARN] {env_id} marked as degraded after "
                    f"{failure_counts[env_id]} consecutive failures.",
                    flush=True,
                )


def main() -> int:
    load_dotenv()

    interval = int(os.getenv("HEALTH_INTERVAL_SECONDS", DEFAULT_INTERVAL_SECONDS))

    print("Starting sandbox health poller...", flush=True)
    print(f"State directory: {ENVS_DIR}", flush=True)
    print(f"Poll interval: {interval} seconds", flush=True)

    failure_counts: dict[str, int] = {}

    while True:
        try:
            poll_once(failure_counts)
            time.sleep(interval)

        except KeyboardInterrupt:
            print("\nStopping health poller.", flush=True)
            return 0

        except Exception as exc:
            print(f"[ERROR] Health poller error: {exc}", file=sys.stderr, flush=True)
            time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())