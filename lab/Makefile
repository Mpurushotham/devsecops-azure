# =============================================================================
# Platform lab — automation entrypoint
# =============================================================================
# Everything CI does, a platform engineer can run locally with the same command.
# If a check only exists in the pipeline, it gets discovered at PR time; if it
# only exists here, it gets skipped. Both run the same targets.
#
#   make help              list targets
#   make check             everything CI runs, in CI order
#   make bootstrap         create remote state + OIDC federation (once)
#   make plan ENV=dev      plan an environment
#   make apply ENV=dev     apply an environment
# =============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV          ?= dev
TF_DIR       := terraform/envs/$(ENV)
CHART_DIR    := charts/dotnet-service
REPO_ROOT    := $(shell git rev-parse --show-toplevel)
TFLINT_CFG   := $(REPO_ROOT)/.tflint.hcl
TRIVY_IGNORE := $(REPO_ROOT)/.trivyignore.yaml

VALID_ENVS := dev staging prod

# Fail early and clearly rather than emitting a confusing Terraform error.
define check_env
	@if ! echo "$(VALID_ENVS)" | grep -qw "$(ENV)"; then \
		echo "ERROR: ENV must be one of: $(VALID_ENVS) (got '$(ENV)')"; exit 1; \
	fi
endef

define require
	@command -v $(1) >/dev/null 2>&1 || { \
		echo "ERROR: $(1) is not installed. See README.md prerequisites."; exit 1; }
endef

.PHONY: help
help: ## Show this help
	@echo "Platform lab — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Set ENV=dev|staging|prod (current: $(ENV))"

# ── Aggregate ────────────────────────────────────────────────────────────────
.PHONY: check
check: fmt-check lint validate scan chart-test ## Run every CI check locally
	@echo ""
	@echo "All checks passed."

# ── Terraform ────────────────────────────────────────────────────────────────
.PHONY: fmt
fmt: ## Format all Terraform
	$(call require,terraform)
	terraform fmt -recursive terraform/

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting
	$(call require,terraform)
	terraform fmt -check -recursive -diff terraform/

.PHONY: lint
lint: ## tflint across all modules and environments
	$(call require,tflint)
	@FAILED=0; \
	for dir in terraform/modules/*/ terraform/envs/*/ terraform/bootstrap/; do \
		echo "--- tflint $$dir"; \
		( cd "$$dir" && tflint --init --config="$(TFLINT_CFG)" >/dev/null \
		  && tflint --config="$(TFLINT_CFG)" --format compact ) || FAILED=1; \
	done; \
	exit $$FAILED

.PHONY: validate
validate: ## terraform validate across all roots
	$(call require,terraform)
	@FAILED=0; \
	for dir in terraform/modules/*/ terraform/envs/*/ terraform/bootstrap/; do \
		echo "--- validate $$dir"; \
		( cd "$$dir" && terraform init -backend=false -input=false >/dev/null \
		  && terraform validate ) || FAILED=1; \
	done; \
	exit $$FAILED

.PHONY: scan
scan: ## Trivy IaC scan (CRITICAL blocks, matching the CI gate)
	$(call require,trivy)
	trivy config terraform/ \
		--severity CRITICAL,HIGH \
		--ignorefile $(TRIVY_IGNORE) \
		--exit-code 1

.PHONY: init
init: ## terraform init against the remote backend (needs backend.hcl)
	$(call check_env)
	$(call require,terraform)
	@test -f $(TF_DIR)/backend.hcl || { \
		echo "ERROR: $(TF_DIR)/backend.hcl not found."; \
		echo "Generate it with: make backend-config ENV=$(ENV)"; exit 1; }
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl -reconfigure

.PHONY: plan
plan: ## terraform plan for ENV
	$(call check_env)
	$(call require,terraform)
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: apply
apply: ## terraform apply for ENV (prompts unless AUTO_APPROVE=1)
	$(call check_env)
	$(call require,terraform)
	@if [ "$(ENV)" = "prod" ] && [ "$${AUTO_APPROVE:-0}" = "1" ]; then \
		echo "ERROR: refusing AUTO_APPROVE against prod. Use the pipeline."; exit 1; \
	fi
	cd $(TF_DIR) && terraform apply $${AUTO_APPROVE:+-auto-approve} tfplan

.PHONY: destroy
destroy: ## terraform destroy for ENV (blocked for prod)
	$(call check_env)
	@if [ "$(ENV)" = "prod" ]; then \
		echo "ERROR: destroy is blocked for prod. Do it deliberately, not with make."; exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy

.PHONY: output
output: ## Show terraform outputs for ENV
	$(call check_env)
	cd $(TF_DIR) && terraform output

.PHONY: bootstrap
bootstrap: ## Create remote state and OIDC federation (run once per subscription)
	$(call require,terraform)
	@echo "Bootstrapping remote state. This root keeps local state until you run"
	@echo "'terraform init -migrate-state' afterwards."
	cd terraform/bootstrap && terraform init && terraform apply

.PHONY: backend-config
backend-config: ## Write backend.hcl for ENV from the bootstrap outputs
	$(call check_env)
	@cd terraform/bootstrap && \
		terraform output -json backend_config_hcl \
		| python3 -c "import json,sys;print(json.load(sys.stdin)['$(ENV)'])" \
		> "$(CURDIR)/$(TF_DIR)/backend.hcl"
	@echo "Wrote $(TF_DIR)/backend.hcl"

# ── Helm ─────────────────────────────────────────────────────────────────────
.PHONY: chart-test
chart-test: chart-lint chart-template chart-policy ## All chart checks

.PHONY: chart-lint
chart-lint: ## helm lint
	$(call require,helm)
	helm lint $(CHART_DIR) \
		--set image.repository=example.azurecr.io/svc \
		--set image.tag=test

.PHONY: chart-template
chart-template: ## Render the chart to /tmp/rendered.yaml
	$(call require,helm)
	@helm template test $(CHART_DIR) \
		--namespace payments \
		--set image.repository=example.azurecr.io/svc \
		--set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
		--set serviceAccount.workloadIdentityClientId=00000000-0000-0000-0000-000000000000 \
		> /tmp/rendered.yaml
	@echo "Rendered $$(grep -c '^kind:' /tmp/rendered.yaml) manifests to /tmp/rendered.yaml"

.PHONY: chart-policy
chart-policy: chart-template ## Assert the platform security contract on rendered output
	@python3 scripts/assert_security_contract.py /tmp/rendered.yaml

# ── Application ──────────────────────────────────────────────────────────────
.PHONY: app-build
app-build: ## Build the payments-api container
	$(call require,docker)
	docker build \
		--build-arg VERSION=$$(git describe --tags --always) \
		--build-arg GIT_COMMIT=$$(git rev-parse HEAD) \
		-t payments-api:local \
		apps/payments-api

.PHONY: app-scan
app-scan: app-build ## Scan the locally built image
	$(call require,trivy)
	trivy image payments-api:local --severity CRITICAL,HIGH --exit-code 1

# ── Cluster ──────────────────────────────────────────────────────────────────
.PHONY: kubeconfig
kubeconfig: ## Fetch AKS credentials for ENV
	$(call check_env)
	$(call require,az)
	@RG=$$(cd $(TF_DIR) && terraform output -raw aks_resource_group); \
	NAME=$$(cd $(TF_DIR) && terraform output -raw aks_cluster_name); \
	az aks get-credentials --resource-group "$$RG" --name "$$NAME" --overwrite-existing

.PHONY: argocd-bootstrap
argocd-bootstrap: ## Apply the app-of-apps root (everything else follows from git)
	$(call require,kubectl)
	kubectl apply -f kubernetes/apps/appproject.yaml
	kubectl apply -f kubernetes/apps/app-of-apps.yaml
	@echo "Root Application applied. ArgoCD will converge the rest."

.PHONY: clean
clean: ## Remove local Terraform and render artefacts
	find terraform -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	find terraform -name 'tfplan' -delete 2>/dev/null || true
	rm -f /tmp/rendered.yaml
	@echo "Cleaned."
