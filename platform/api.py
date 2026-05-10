from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

ROOT_DIR = Path(__file__).resolve().parents[1]
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
CREATE_SCRIPT = ROOT_DIR / "platform" / "create_env.sh"
DESTROY_SCRIPT = ROOT_DIR / "platform" / "destroy_env.sh"
OUTAGE_SCRIPT = ROOT_DIR / "platform" / "simulate_outage.sh"

app = FastAPI(title="DevOps Sandbox API")


class EnvCreate(BaseModel):
    name: str
    ttl: int | None = None


class OutageCreate(BaseModel):
    mode: str


def run_script(args: list[str]) -> str:
    result = subprocess.run(
        args,
        cwd=ROOT_DIR,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise HTTPException(status_code=400, detail=detail)

    return result.stdout


def read_state(env_id: str) -> dict[str, Any]:
    path = ENVS_DIR / f"{env_id}.json"

    if not path.exists():
        raise HTTPException(status_code=404, detail="environment not found")

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=500, detail="state file is not valid JSON") from exc


def tail(path: Path, lines: int) -> list[str]:
    if not path.exists():
        return []

    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return content[-lines:]


@app.get("/health")
def api_health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/envs")
def create_env(payload: EnvCreate) -> dict[str, Any]:
    args = [str(CREATE_SCRIPT), payload.name]

    if payload.ttl is not None:
        args.append(str(payload.ttl))

    output = run_script(args)
    env_id = ""

    for line in output.splitlines():
        if line.startswith("ID: "):
            env_id = line.split("ID: ", 1)[1].strip()
            break

    if not env_id:
        raise HTTPException(status_code=500, detail="environment was created but ID was not found")

    state = read_state(env_id)
    return {"message": "created", "environment": state, "output": output}


@app.get("/envs")
def list_envs() -> list[dict[str, Any]]:
    now = int(time.time())
    envs: list[dict[str, Any]] = []

    for state_file in sorted(ENVS_DIR.glob("*.json")):
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue

        created_at = int(state.get("created_at", now))
        ttl = int(state.get("ttl", 0))
        state["ttl_remaining"] = max(0, created_at + ttl - now)
        envs.append(state)

    return envs


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str) -> dict[str, str]:
    output = run_script([str(DESTROY_SCRIPT), env_id])
    return {"message": "destroyed", "output": output}


@app.get("/envs/{env_id}/logs")
def get_logs(env_id: str) -> dict[str, Any]:
    read_state(env_id)
    return {"env_id": env_id, "lines": tail(LOGS_DIR / env_id / "app.log", 100)}


@app.get("/envs/{env_id}/health")
def get_health(env_id: str) -> dict[str, Any]:
    read_state(env_id)
    return {"env_id": env_id, "lines": tail(LOGS_DIR / env_id / "health.log", 10)}


@app.post("/envs/{env_id}/outage")
def simulate_outage(env_id: str, payload: OutageCreate) -> dict[str, str]:
    output = run_script([str(OUTAGE_SCRIPT), "--env", env_id, "--mode", payload.mode])
    return {"message": "outage command completed", "output": output}
