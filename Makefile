SHELL := /bin/bash

-include .env

APP_IMAGE ?= sandbox-demo-app
NGINX_CONTAINER ?= sandbox-nginx
NGINX_PORT ?= 80
API_HOST ?= 127.0.0.1
API_PORT ?= 8000

.PHONY: up down create destroy logs health simulate clean

up:
	@mkdir -p envs logs nginx/conf.d
	@test -d .venv || python3 -m venv .venv
	@.venv/bin/python -m pip install -r requirements.txt
	@docker build -t $(APP_IMAGE) .
	@docker inspect $(NGINX_CONTAINER) >/dev/null 2>&1 || docker run -d --name $(NGINX_CONTAINER) -p $(NGINX_PORT):80 -v "$(CURDIR)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$(CURDIR)/nginx/conf.d:/etc/nginx/conf.d:ro" nginx:1.27-alpine >/dev/null
	@docker start $(NGINX_CONTAINER) >/dev/null 2>&1 || true
	@nohup ./platform/cleanup_daemon.sh >/dev/null 2>&1 & echo $$! > .cleanup.pid
	@nohup ./monitor/health_poller.py >> logs/health_poller.log 2>&1 & echo $$! > .monitor.pid
	@nohup .venv/bin/python -m uvicorn platform.api:app --host $(API_HOST) --port $(API_PORT) >> logs/api.log 2>&1 & echo $$! > .api.pid
	@echo "Platform is up: http://localhost:$(NGINX_PORT)"

down:
	@for pid in .api.pid .monitor.pid .cleanup.pid; do [ ! -f $$pid ] || kill $$(cat $$pid) >/dev/null 2>&1 || true; rm -f $$pid; done
	@for state in envs/*.json; do [ ! -e "$$state" ] || ./platform/destroy_env.sh "$$(basename "$$state" .json)" || true; done
	@docker rm -f $(NGINX_CONTAINER) >/dev/null 2>&1 || true
	@echo "Platform stopped."

create:
	@read -r -p "Environment name: " name; read -r -p "TTL in seconds [1800]: " ttl; ./platform/create_env.sh "$$name" "$${ttl:-1800}"

destroy:
	@./platform/destroy_env.sh "$(ENV)"

logs:
	@tail -n 100 -f "logs/$(ENV)/app.log"

health:
	@python3 ./platform/list_health.py

simulate:
	@./platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean:
	@$(MAKE) down
	@find envs -type f ! -name ".gitkeep" -delete
	@find logs -type f ! -name ".gitkeep" -delete
	@find logs -type d -empty -delete
	@find nginx/conf.d -type f ! -name ".gitkeep" -delete
	@echo "State and logs removed."
