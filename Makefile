# agent-swarm-local — operator shortcuts.
# Every docker compose call uses both env files + the fixed project name.
# Run `make` or `make help` to list targets.

SHELL := /bin/bash
DC := docker compose --env-file versions.env --env-file .env -p agent-swarm-local
STORAGE := minio minio-init agent-fs api
AGENTS := tars chase rocky einstein
DASHBOARD_URL ?= https://app.agent-swarm.dev
API_URL := http://127.0.0.1:3013

.DEFAULT_GOAL := help
.PHONY: help up start stop down restart restart-agents pause ps status logs \
        verify health backup restore pull pins arch agents set-model dashboard dashboard-link

help: ## List available commands
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  make %-16s %s\n", $$1, $$2}'

up: ## Start the full stack (storage+API, then recreate agents)
	$(DC) up -d $(STORAGE)
	$(DC) up -d --force-recreate $(AGENTS)
	@echo ">> stack up — run 'make verify'"

start: up ## Alias for 'up'

stop: ## Stop everything (keeps containers + volumes)
	$(DC) stop

down: ## Remove containers but KEEP volumes (never uses -v)
	$(DC) down

restart: ## Full graceful restart (down, then up)
	$(MAKE) down
	$(MAKE) up

restart-agents: ## Recreate only the agents (use after any reuse/host reboot)
	$(DC) up -d --force-recreate $(AGENTS)
	@echo ">> agents recreated"

pause: ## Stop only the agents (storage + API stay up)
	$(DC) stop $(AGENTS)

ps: ## Show container status
	$(DC) ps

status: ps ## Alias for 'ps'

logs: ## Tail logs (optionally: make logs SERVICE=api)
	$(DC) logs -f $(SERVICE)

verify: ## Health + agent-fs capabilities checks
	@bash scripts/verify.sh

health: verify ## Alias for 'verify'

dashboard: ## Open the hosted dashboard (then paste API URL + key in Settings)
	@echo ">> Opening $(DASHBOARD_URL)"
	@echo "   In the gear/Settings menu, add a connection:"
	@echo "     API URL: $(API_URL)"
	@echo "     API Key: value of API_KEY in ./.env  (keep it secret)"
	@command -v open >/dev/null 2>&1 && open "$(DASHBOARD_URL)" || echo "   Open $(DASHBOARD_URL) in your browser."

dashboard-link: ## Print a one-click dashboard URL (WARNING: embeds your API key)
	@key=$$(grep -E '^API_KEY=' .env | cut -d= -f2-); \
	echo "$(DASHBOARD_URL)/?apiUrl=$(API_URL)&apiKey=$$key"

agents: ## Show registered agents (id, role, harness, status)
	@docker exec agent-swarm-local-api-1 sh -c 'curl -fsS -H "Authorization: Bearer $$API_KEY" http://localhost:3013/api/agents' \
		| python3 -c "import sys,json;[print(f\"  {a['name']:13} {a['id']} {'lead' if a['isLead'] else 'worker'}/{a['harnessProvider']} status={a['status']}\") for a in json.load(sys.stdin)['agents']]"

set-model: ## Set an agent's model live (no restart) — usage: make set-model AGENT=<name|id> MODEL=<model-id>
	@test -n "$(AGENT)" -a -n "$(MODEL)" || { echo "usage: make set-model AGENT=<name|id> MODEL=<model-id>"; exit 1; }
	@bash scripts/set-model.sh "$(AGENT)" "$(MODEL)"

backup: ## Consistent offline backup (stops stack, archives, restarts, verifies)
	@bash scripts/backup.sh

restore: ## DESTRUCTIVE restore — usage: make restore BACKUP=backups/<timestamp>
	@test -n "$(BACKUP)" || { echo "usage: make restore BACKUP=backups/<timestamp>"; exit 1; }
	@bash scripts/restore.sh "$(BACKUP)" --yes-destroy-current-state

pull: ## Pull pinned images without starting anything
	$(DC) pull

pins: ## Show resolved image references (tag+digest)
	$(DC) config --images

arch: ## Show architecture of running images
	@for s in $(STORAGE) $(AGENTS); do \
		cid=$$($(DC) ps -q $$s 2>/dev/null); \
		[ -n "$$cid" ] && printf "  %-14s %s\n" "$$s" "$$(docker image inspect -f '{{.Architecture}}/{{.Os}}' $$(docker inspect -f '{{.Image}}' $$cid))"; \
	done
