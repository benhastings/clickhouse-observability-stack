SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

HELM_VERSION := v3.22.0
KUBECONFORM_VERSION := v0.8.0
YQ_VERSION := v4.54.1
ACTIONLINT_VERSION := v1.7.12
YAMLLINT_VERSION := 1.38.0
SHELLCHECK_VERSION := 0.11.0.1
HELM_UNITTEST_VERSION := v1.1.2
KUBE_VERSION := 1.37.0
KIND_VERSION := v0.33.0
KUBECTL_VERSION := v1.37.1
GOLDEN := tests/golden

HELM_OUT := dist/helm

LOCAL_CHARTS := $(patsubst %/Chart.yaml,%,$(wildcard cluster-nodes/*/Chart.yaml tests/charts/*/Chart.yaml))
UNIT_TEST_CHARTS := $(patsubst %/tests/,%,$(dir $(wildcard cluster-configs/app-of-apps/tests/*_test.yaml cluster-configs/stack/tests/*_test.yaml cluster-nodes/*/tests/*_test.yaml tests/charts/*/tests/*_test.yaml)))

VENV := .venv

SHELL_SCRIPTS := $(wildcard scripts/*.sh scripts/*.bash) git/hooks/pre-commit

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_\/-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Setup

.PHONY: setup
setup: setup/tools setup/hooks ## Install every tool the checks need, plus the git hooks

.PHONY: setup/tools
setup/tools: setup/tools/go setup/tools/helm-unittest setup/tools/python setup/tools/node ## Install helm, helm-unittest, kubeconform, yq, actionlint, yamllint, shellcheck, cspell

.PHONY: setup/tools/go
setup/tools/go:
	go install helm.sh/helm/v3/cmd/helm@$(HELM_VERSION)
	go install github.com/yannh/kubeconform/cmd/kubeconform@$(KUBECONFORM_VERSION)
	go install github.com/mikefarah/yq/v4@$(YQ_VERSION)
	go install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)

.PHONY: setup/tools/helm-unittest
setup/tools/helm-unittest:
	tmp="$$(mktemp -d)" && \
	git clone -q --depth 1 --branch $(HELM_UNITTEST_VERSION) https://github.com/helm-unittest/helm-unittest "$$tmp" && \
	(cd "$$tmp" && go build -o "$$(go env GOPATH)/bin/helm-unittest" ./cmd/helm-unittest) && \
	rm -rf "$$tmp"

.PHONY: setup/tools/cluster
setup/tools/cluster: ## Install kind and kubectl, which only the local cluster and test/e2e need
	go install sigs.k8s.io/kind@$(KIND_VERSION)
	curl -fsSLo "$$(go env GOPATH)/bin/kubectl" \
		"https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$$(go env GOOS)/$$(go env GOARCH)/kubectl"
	chmod +x "$$(go env GOPATH)/bin/kubectl"

.PHONY: setup/tools/python
setup/tools/python:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --disable-pip-version-check \
		yamllint==$(YAMLLINT_VERSION) shellcheck-py==$(SHELLCHECK_VERSION)

.PHONY: setup/tools/node
setup/tools/node:
	npm ci --no-audit --no-fund

.PHONY: setup/hooks
setup/hooks: ## Point git at git/hooks so the pre-commit check runs
	git config core.hooksPath git/hooks

##@ Checks

.PHONY: check
check: check/lint check/schema check/golden check/manifests check/credentials ## The whole gate CI runs

.PHONY: check/lint
check/lint: check/yaml check/shell check/structure check/workflows check/spelling ## Offline checks, what the pre-commit hook runs

.PHONY: check/yaml
check/yaml: ## yamllint every YAML file against .yamllint.yaml
	$(VENV)/bin/yamllint --strict .

.PHONY: check/shell
check/shell: ## shellcheck every script
	$(VENV)/bin/shellcheck $(SHELL_SCRIPTS)

.PHONY: check/structure
check/structure: ## Enforce the cluster-configs and cluster-nodes layout in AGENTS.md
	scripts/check-structure.bash

.PHONY: check/schema
check/schema: deps ## Fail when a values.schema.json or the common values table is stale, or the schema accepts deployment.replica
	@tmp="$$(mktemp -d)" && trap 'rm -rf "$$tmp"' EXIT && scripts/generate-schemas.bash "$$tmp" && \
	for f in $$(cd "$$tmp" && find . -name values.schema.json) ./helm-templates/common/README.md; do \
	  diff -u "$$f" "$$tmp/$$f" >/dev/null || { echo "check/schema: $$f is stale; run make generate"; exit 1; }; \
	done
	@if helm template fixture tests/charts/common-fixture -f tests/schema/bad-replica.yaml >/dev/null 2>&1; then \
	  echo 'check/schema: the common schema accepted deployment.replica'; exit 1; \
	else echo 'check/schema: ok'; fi

.PHONY: check/golden
check/golden: deps ## Fail when tests/golden differs from a fresh render
	@tmp="$$(mktemp -d)" && trap 'rm -rf "$$tmp"' EXIT && \
	KUBE_VERSION=$(KUBE_VERSION) scripts/render.bash "$$tmp" && \
	if ! diff -ru $(GOLDEN) "$$tmp"; then \
		echo "tests/golden is stale: run make generate and commit the result"; exit 1; \
	fi

.PHONY: check/workflows
check/workflows: ## actionlint the GitHub Actions workflows
	actionlint

.PHONY: check/spelling
check/spelling: ## cspell against cspell.json (American and British English)
	npm run --silent spell

.PHONY: check/manifests
check/manifests: ## kubeconform tests/golden against pinned schemas; require memory limits and pinned images
	KUBE_VERSION=$(KUBE_VERSION) scripts/check-manifests.bash

.PHONY: check/credentials
check/credentials: ## Fail when tests/golden renders a Secret value or a literal password, token or client secret
	scripts/check-credentials.bash tests/golden

##@ Generate

.PHONY: generate
generate: deps ## Re-render tests/golden: every node, as Argo CD would deploy it, for every environment
	scripts/generate-schemas.bash
	rm -rf $(GOLDEN)
	KUBE_VERSION=$(KUBE_VERSION) scripts/render.bash $(GOLDEN)

.PHONY: render
render: deps ## Render one environment to dist/manifests/<env>/, one file per object by namespace, CRDs included: ENV=<env>
	@test -n '$(ENV)' || { echo 'usage: make render ENV=<env>'; exit 1; }
	@tmp="$$(mktemp -d)" && trap 'rm -rf "$$tmp"' EXIT && \
	KUBE_VERSION=$(KUBE_VERSION) scripts/render.bash "$$tmp" '$(ENV)' && \
	scripts/split-manifests.bash "$$tmp/$(ENV)" dist/manifests/'$(ENV)'

##@ Tests

.PHONY: deps
deps: ## Rebuild every local chart's file:// dependencies from Chart.lock
	@for chart in $(sort $(LOCAL_CHARTS)); do \
		helm dependency build "$$chart" >/dev/null || exit 1; \
	done
	@# After the nodes, because it packages each node with its common tarball.
	@helm dependency build cluster-configs/stack >/dev/null

.PHONY: test
test: test/unit test/credentials ## Every offline test

.PHONY: test/e2e
test/e2e: ## Needs Docker: kind cluster at REVISION (default main), wait for Argo CD, then query the stack
	scripts/kind-up.sh $(REVISION)
	scripts/e2e.bash

.PHONY: test/credentials
test/credentials: ## Prove check-credentials.bash rejects the leaky fixture in tests/credentials/leaky
	@if scripts/check-credentials.bash tests/credentials/leaky >/dev/null 2>&1; then \
	  echo 'test/credentials: check-credentials.bash passed a render that leaks a password'; exit 1; \
	else echo 'test/credentials: ok, the leaky fixture is rejected'; fi

.PHONY: test/unit
test/unit: deps ## helm-unittest suites for the common library and every cluster node
	helm-unittest --strict $(sort $(UNIT_TEST_CHARTS))

##@ Environments

.PHONY: env/new
env/new: ## Write a commented skeleton for a new environment: NAME=<env>, FORCE=1 to overwrite
	NAME='$(NAME)' FORCE='$(FORCE)' scripts/env-new.bash

##@ Helm

.PHONY: helm/template
helm/template: deps ## Render ENV=<env> for a Helm install into dist/helm/<env>: the stack umbrella and the operator
	scripts/values-for-helm.bash '$(ENV)' $(HELM_OUT)/$(ENV)
	helm template clickhouse-operator cluster-nodes/clickhouse-operator --namespace clickhouse-operator \
		--kube-version $(KUBE_VERSION) -f $(HELM_OUT)/$(ENV)/clickhouse-operator.yaml >$(HELM_OUT)/$(ENV)/clickhouse-operator-manifests.yaml
	helm template stack cluster-configs/stack --namespace observability \
		--kube-version $(KUBE_VERSION) -f $(HELM_OUT)/$(ENV)/stack.yaml >$(HELM_OUT)/$(ENV)/stack-manifests.yaml

.PHONY: helm/install
helm/install: deps ## Install ENV=<env> with Helm into the current context: the operator, its CRDs, then the stack
	HELM_OUT=$(HELM_OUT) scripts/helm-install.bash install '$(ENV)'

.PHONY: helm/uninstall
helm/uninstall: ## Uninstall both Helm releases of ENV=<env>; CRDs, namespaces, Secrets and volumes stay
	HELM_OUT=$(HELM_OUT) scripts/helm-install.bash uninstall '$(ENV)'

##@ Local cluster

.PHONY: cluster/up
cluster/up: ## Create the kind cluster, install Argo CD and apply the local app-of-apps (REVISION=<git ref> to deploy a branch)
	scripts/kind-up.sh $(REVISION)

.PHONY: cluster/bootstrap
cluster/bootstrap: ## Install Argo CD (if missing) and ENV=<env>'s app-of-apps on the current context, after preflight
	scripts/bootstrap.bash '$(ENV)' $(REVISION)

.PHONY: cluster/preflight
cluster/preflight: ## Check the current kube context against an environment before its first sync: ENV=<env>
	ENV='$(ENV)' KUBE_VERSION=$(KUBE_VERSION) scripts/preflight.bash

.PHONY: cluster/down
cluster/down: ## Delete the kind cluster
	scripts/kind-down.sh

.PHONY: cluster/restart
cluster/restart: ## Roll one app's pods, for a Secret rotated outside the cluster such as in Vault: APP=<app>
	scripts/restart.bash '$(APP)'

.PHONY: cluster/port-forward
cluster/port-forward: ## Forward Grafana, Argo CD, Cerberus and OTLP to localhost
	scripts/port-forward.sh

##@ Local development (no Argo CD)

.PHONY: dev/up
dev/up: deps ## Create the kind cluster and helm-install every app but demo-load from the working tree
	scripts/dev.bash up

.PHONY: dev/apply
dev/apply: deps ## Redeploy one app from the working tree: APP=<app>, e.g. APP=grafana after editing a dashboard
	scripts/dev.bash apply $(APP)

.PHONY: dev/load
dev/load: deps ## Start the demo load
	scripts/dev.bash apply demo-load

.PHONY: dev/load/stop
dev/load/stop: ## Stop the demo load
	scripts/dev.bash remove demo-load

.PHONY: dev/dashboards
dev/dashboards: ## Save every dashboard in Grafana to cluster-nodes/grafana/dashboards/, to commit
	scripts/dev.bash dashboards

.PHONY: dev/port-forward
dev/port-forward: ## Forward Grafana, Cerberus and OTLP to localhost
	scripts/port-forward.sh

.PHONY: dev/down
dev/down: ## Delete the kind cluster
	scripts/kind-down.sh
