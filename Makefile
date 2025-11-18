# Makefile for MediaWiki Managed Docker

# Variables
IMAGE_NAME := mediawiki-docker
IMAGE_TAG := 1.43
REGISTRY := ghcr.io
REPO_OWNER := nkcx
FULL_IMAGE := $(REGISTRY)/$(REPO_OWNER)/$(IMAGE_NAME):$(IMAGE_TAG)

# Docker Compose settings
COMPOSE_FILE := docker-compose.yml
COMPOSE_EXAMPLE := docker-compose.example.yml

.PHONY: help
help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: build
build: ## Build the Docker image locally
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest

.PHONY: build-no-cache
build-no-cache: ## Build the Docker image without cache
	docker build --no-cache -t $(IMAGE_NAME):$(IMAGE_TAG) .
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest

.PHONY: push
push: ## Push image to registry
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(FULL_IMAGE)
	docker push $(FULL_IMAGE)

.PHONY: pull
pull: ## Pull image from registry
	docker pull $(FULL_IMAGE)

.PHONY: init
init: ## Initialize project (create .env from example)
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env file. Please edit it with your configuration."; \
	else \
		echo ".env file already exists. Skipping."; \
	fi
	@if [ ! -f $(COMPOSE_FILE) ]; then \
		cp $(COMPOSE_EXAMPLE) $(COMPOSE_FILE); \
		echo "Created docker-compose.yml from example."; \
	else \
		echo "docker-compose.yml already exists. Skipping."; \
	fi

.PHONY: up
up: ## Start services in detached mode
	docker-compose up -d

.PHONY: down
down: ## Stop and remove services
	docker-compose down

.PHONY: restart
restart: ## Restart services
	docker-compose restart

.PHONY: logs
logs: ## Show logs (follow mode)
	docker-compose logs -f

.PHONY: logs-mediawiki
logs-mediawiki: ## Show MediaWiki logs only
	docker-compose logs -f mediawiki

.PHONY: shell
shell: ## Open shell in MediaWiki container
	docker-compose exec mediawiki bash

.PHONY: update
update: ## Update database schema
	docker-compose exec mediawiki php maintenance/run.php update.php

.PHONY: extensions
extensions: ## List installed extensions
	docker-compose exec mediawiki ls -la /extensions

.PHONY: skins
skins: ## List installed skins
	docker-compose exec mediawiki ls -la /skins

.PHONY: config
config: ## View generated LocalSettings.php
	docker-compose exec mediawiki cat /config/LocalSettings.php

.PHONY: clean
clean: ## Remove containers, volumes, and networks
	docker-compose down -v
	docker volume prune -f

.PHONY: clean-all
clean-all: clean ## Remove everything including images
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest || true

.PHONY: test
test: build up ## Build image and start test environment
	@echo "Waiting for services to start..."
	@sleep 10
	@echo "Testing MediaWiki..."
	@curl -f http://localhost:8080/ || (echo "MediaWiki not responding"; exit 1)
	@echo "Test passed!"

.PHONY: backup
backup: ## Backup volumes to ./backups/
	@mkdir -p backups
	@echo "Backing up database..."
	@docker-compose exec -T database mysqldump -u root -p$${DB_ROOT_PASSWORD} mediawiki > backups/db-backup-$$(date +%Y%m%d-%H%M%S).sql
	@echo "Backing up uploads..."
	@docker run --rm -v $$(docker volume ls -q | grep uploads):/source -v $$(pwd)/backups:/backup alpine tar czf /backup/uploads-$$(date +%Y%m%d-%H%M%S).tar.gz -C /source .
	@echo "Backup complete!"

.PHONY: restore-db
restore-db: ## Restore database from most recent backup
	@latest=$$(ls -t backups/db-backup-*.sql | head -1); \
	if [ -z "$$latest" ]; then \
		echo "No database backup found"; \
		exit 1; \
	fi; \
	echo "Restoring from $$latest..."; \
	docker-compose exec -T database mysql -u root -p$${DB_ROOT_PASSWORD} mediawiki < $$latest

.PHONY: version
version: ## Show MediaWiki version
	docker-compose exec mediawiki php maintenance/run.php version

.PHONY: user-create
user-create: ## Create a new user (interactive)
	docker-compose exec mediawiki php maintenance/run.php createAndPromote.php

.PHONY: validate
validate: ## Validate docker-compose.yml
	docker-compose config --quiet && echo "docker-compose.yml is valid"

.PHONY: stats
stats: ## Show container resource usage
	docker stats --no-stream

.PHONY: prune
prune: ## Remove unused Docker resources
	docker system prune -f
	docker volume prune -f

# Development targets
.PHONY: dev-build
dev-build: ## Build with development settings
	docker build --build-arg MEDIAWIKI_VERSION=latest -t $(IMAGE_NAME):dev .

.PHONY: dev-up
dev-up: dev-build ## Start development environment
	docker-compose -f docker-compose.yml up -d

.PHONY: lint
lint: ## Lint shell scripts
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; exit 1; }
	shellcheck scripts/*.sh

.PHONY: security-scan
security-scan: ## Scan image for vulnerabilities
	@command -v trivy >/dev/null 2>&1 || { echo "trivy not installed"; exit 1; }
	trivy image $(IMAGE_NAME):$(IMAGE_TAG)
