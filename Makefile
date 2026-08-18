SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Anything preflight installed takes precedence, matching scripts/lib.sh, while
# still falling back to a system-wide install.
export PATH := $(CURDIR)/.bin:$(PATH)

.PHONY: help preflight up down clean build credentials deploy-db deploy smoke all \
        jenkins ci scale-demo lint template logs port-forward compose-up compose-down

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

preflight: ## Verify the toolchain and install pinned versions of anything missing
	@./scripts/preflight.sh

up: ## Create the kind cluster and install the ingress controller
	@./scripts/cluster-up.sh

down: ## Delete the kind cluster
	@./scripts/cluster-down.sh

clean: ## Delete the cluster and remove locally built images
	@./scripts/cluster-down.sh --purge

build: ## Build the application image and load it into the cluster
	@./scripts/build-and-load.sh

credentials: ## Create the shared MongoDB credentials Secret (never rotates existing ones)
	@./scripts/create-credentials.sh

deploy-db: ## Deploy MongoDB from the pinned Bitnami chart
	@./scripts/deploy-database.sh

deploy: ## Deploy the application chart using the last built image
	@./scripts/deploy-app.sh

smoke: ## Run the chart test hook and request the app from outside the cluster
	@./scripts/smoke-test.sh

jenkins: ## Deploy the in-cluster Jenkins (pipeline and config as code)
	@./scripts/deploy-jenkins.sh

ci: ## Trigger the Jenkins pipeline and follow it to completion
	@./scripts/run-pipeline.sh

scale-demo: ## Drive the HPA through scale-up and scale-down with real load
	@./scripts/scale-demo.sh

all: up build deploy-db deploy smoke jenkins ## Cluster, database, application, CI/CD

lint: ## Lint the shell scripts and the Helm chart
	@docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh docker/entrypoint.sh
	@helm lint charts/taskmanager --values charts/taskmanager/values-local.yaml

template: ## Render the application chart to stdout
	@helm template taskmanager charts/taskmanager \
		--namespace taskmanager --values charts/taskmanager/values-local.yaml

logs: ## Follow the application logs from every replica
	@kubectl --namespace taskmanager logs -f --prefix \
		-l app.kubernetes.io/name=taskmanager

port-forward: ## Serve the app on localhost:8081 without going through the ingress
	@echo "http://localhost:8081/"
	@kubectl --namespace taskmanager port-forward svc/taskmanager 8081:80

compose-up: ## Run the stack locally with Docker Compose
	@docker compose up -d --build

compose-down: ## Stop the Compose stack, keeping the database volume
	@docker compose down
