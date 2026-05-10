from fastapi import FastAPI
from datetime import datetime, timezone
import os

app = FastAPI(title="Sandbox Demo App")


@app.get("/")
def root():
    env_id = os.getenv("ENV_ID", "local-dev")

    return {
        "message": "Hello from sandbox",
        "env_id": env_id,
        "status": "running"
    }


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "sandbox-demo-app",
        "timestamp": datetime.now(timezone.utc).isoformat()
    }