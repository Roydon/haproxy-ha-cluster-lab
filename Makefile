# Detect a real engine binary -- `docker` is often only a shell alias (e.g.
# `docker=podman`), which doesn't exist for a non-interactive Make recipe.
ENGINE := $(shell command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1 && echo docker || echo podman)
COMPOSE := $(shell $(ENGINE) compose version >/dev/null 2>&1 && echo "$(ENGINE) compose" || echo "docker-compose")

.PHONY: up up-lite down verify failover load lint deploy ps logs

## Bring up the full topology (3 pg + 3 mysql + 3 redis + 2 app + monitoring).
up: .env
	./scripts/render-mysql-exporter-cnf.sh
	COMPOSE_PROFILES=full $(COMPOSE) up -d --build
	@# Podman's classic compose provider occasionally leaves a container in
	@# `Created` without starting it (see DEVLOG) -- start anything stuck like that.
	@for c in $$($(ENGINE) ps -a --filter status=created --format '{{.Names}}'); do \
		echo "starting stuck container: $$c"; $(ENGINE) start "$$c"; \
	done

## Bring up the CI-sized subset (1 pg leader + 1 replica, 1 mysql primary + 1
## replica, 1 redis, haproxy, prometheus, one app).
up-lite: .env
	./scripts/render-mysql-exporter-cnf.sh
	COMPOSE_PROFILES=lite $(COMPOSE) up -d --build
	@for c in $$($(ENGINE) ps -a --filter status=created --format '{{.Names}}'); do \
		echo "starting stuck container: $$c"; $(ENGINE) start "$$c"; \
	done

down:
	$(COMPOSE) down -v

## Runs every routing check the brief lists and prints a PASS/FAIL table.
verify:
	./scripts/verify.sh

## Kills the Postgres leader and MySQL primary under write load, measures
## downtime and lost acknowledged writes, confirms automatic rejoin.
failover:
	./scripts/failover-test.sh

## A small continuous write load against both databases, for manually watching
## HAProxy/Grafana react to load (Ctrl+C to stop).
load:
	./scripts/load-gen.sh

lint:
	haproxy -c -f haproxy/haproxy.cfg
	yamllint .
	cd ansible && ansible-lint .
	find scripts postgres mysql redis haproxy -name '*.sh' -exec shellcheck {} +

## Apply the Ansible playbook to a real host group, e.g.
##   make deploy HOSTS=app
##   make deploy HOSTS=db INVENTORY=ansible/inventory/production.ini
INVENTORY ?= ansible/inventory/example.ini
deploy:
	@[ -n "$(HOSTS)" ] || { echo "usage: make deploy HOSTS=<group> [INVENTORY=path]"; exit 1; }
	ansible-playbook -i $(INVENTORY) ansible/site.yml --limit "$(HOSTS)"

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

.env:
	cp .env.example .env
	@echo "created .env from .env.example -- edit if you need different credentials"
