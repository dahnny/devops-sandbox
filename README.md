# DevOps Sandbox Platform

This is a small self-service DevOps sandbox. It lets me create short-lived app environments, route traffic to them through Nginx, watch their health, simulate outages, and destroy them manually or after their TTL expires.

The demo app is just a small FastAPI "hello world" app. The main project is the platform around it.

## Architecture

```text
User / Reviewer
      |
      v
  Makefile / API
      |
      +------------------+
      |                  |
      v                  v
 create_env.sh      destroy_env.sh
      |                  |
      v                  v
 Docker app        remove containers
 per env           remove network
      |            archive logs
      v
 Docker network per env
      |
      v
 Nginx container
      |
      v
 http://localhost/env-xxxxxx/

Background workers:
- cleanup_daemon.sh checks TTL every 60 seconds
- monitor/health_poller.py checks /health every 30 seconds
- docker logs -f writes app logs into logs/<env_id>/app.log
```

## Prerequisites

- Linux VM or Linux-like machine
- Docker installed and running
- Python 3 installed
- Port `80` free for Nginx
- Port `8000` free for the API

Copy the example env file if you want to change defaults:

```bash
cp .env.example .env
```

## Quick Start

From a fresh checkout:

```bash
make up
make create
```

When `make create` asks questions, enter a name like `demo` and a TTL like `600`.

The script prints a URL like:

```text
http://localhost/env-abc123/
```

Open that URL in the browser or test it with curl:

```bash
curl http://localhost/env-abc123/
curl http://localhost/env-abc123/health
```

## Main Commands

```bash
make up
make down
make create
make destroy ENV=env-abc123
make logs ENV=env-abc123
make health
make simulate ENV=env-abc123 MODE=crash
make simulate ENV=env-abc123 MODE=recover
make clean
```

## API Endpoints

The API starts on `http://127.0.0.1:8000` when I run `make up`.

```text
POST   /envs
GET    /envs
DELETE /envs/{id}
GET    /envs/{id}/logs
GET    /envs/{id}/health
POST   /envs/{id}/outage
```

Example:

```bash
curl -X POST http://127.0.0.1:8000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"api-demo","ttl":600}'

curl http://127.0.0.1:8000/envs

curl -X POST http://127.0.0.1:8000/envs/env-abc123/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"crash"}'
```

## Full Demo Walkthrough

1. Start the platform:

```bash
make up
```

2. Create an environment:

```bash
make create
```

Use name `demo` and TTL `300`.

3. Check the app:

```bash
curl http://localhost/env-abc123/
curl http://localhost/env-abc123/health
```

4. Check logs:

```bash
make logs ENV=env-abc123
```

5. Check health status:

```bash
make health
```

6. Simulate an outage:

```bash
make simulate ENV=env-abc123 MODE=crash
```

The health poller runs every 30 seconds. After 3 failed checks, the env status becomes `degraded`.

7. Recover the environment:

```bash
make simulate ENV=env-abc123 MODE=recover
```

8. Destroy it manually:

```bash
make destroy ENV=env-abc123
```

If I do not destroy it manually, the cleanup daemon destroys it after the TTL expires.

## How Nginx Routing Works

Nginx runs as one Docker container named `sandbox-nginx`.

Each environment gets:

- one Docker network named `sandbox-net-<env_id>`
- one app container named `sandbox-app-<env_id>`
- one Nginx config file at `nginx/conf.d/<env_id>.conf`

When an environment is created, the script connects the Nginx container to that environment's Docker network. This lets Nginx proxy to the app container by container name.

When the environment is destroyed, the script deletes the Nginx config, reloads Nginx, disconnects Nginx from the network, removes the network, archives logs, and deletes the state file.

## Log Shipping

I used the simple log shipping approach.

On create:

```bash
docker logs -f <container_id> >> logs/<env_id>/app.log &
```

The process ID is saved in `logs/<env_id>/log_shipper.pid` and also in the state file. On destroy, the PID is killed so it does not stay running.

Logs can be queried with:

```bash
make logs ENV=env-abc123
```

## State Files

Each active environment has a JSON state file:

```text
envs/<env_id>.json
```

It stores the ID, name, created time, TTL, status, container name, network name, URL, log path, and outage mode.

State files are written to a temp file first and then moved into place.

## Known Limitations

- This is for one Linux VM only.
- There is no user authentication on the API.
- The demo app image is the same for every environment.
- The API runs as a local Python process, not as a Docker service.
- Nginx uses path-based routing like `/env-abc123/`, not subdomains.
- Prometheus and Grafana are not included.
