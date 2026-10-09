#!/usr/bin/env bash
# Checks the current kube context against an environment file before the first sync. Installs nothing.
# Usage: ENV=<env> [KUBE_VERSION=<x.y.z>] scripts/preflight.bash   (or make cluster/preflight ENV=<env>)
#
# It checks the Kubernetes version against KUBE_VERSION (the version the golden files render against),
# each destination namespace, the Secrets the environment does not create, a StorageClass for ClickHouse,
# the Istio CRDs when global.mesh is istio, and the Vault injector when vault.enabled is true.
set -euo pipefail
cd "$(dirname "$0")/.."

env_name="${ENV:-}"
if [[ -z "$env_name" ]]; then
  echo "preflight: ENV is required, e.g. make cluster/preflight ENV=staging" >&2
  exit 2
fi
values="cluster-configs/overrides/values-$env_name.yaml"
if [[ ! -f "$values" ]]; then
  echo "preflight: $values does not exist; make env/new NAME=$env_name writes a skeleton" >&2
  exit 2
fi

context="$(kubectl config current-context 2>/dev/null || true)"
if ! kubectl get --raw=/version >/dev/null 2>&1; then
  echo "preflight: kubectl cannot reach the cluster (context: ${context:-none})" >&2
  exit 1
fi
echo "==> Preflight for $env_name against context ${context}"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# app_value <app> <yq path under applications.<app>.values>: the environment's value, empty when unset.
app_value() {
  yq ".applications.\"$1\".values$2 // \"\"" "$values"
}

app_enabled() {
  [[ "$(yq ".applications.\"$1\".enabled" "$values")" != false ]]
}

default_namespace="$(yq '.namespace' cluster-configs/app-of-apps/values.yaml)"
operator_namespace="$(yq '.applications.clickhouse-operator.namespace' cluster-configs/app-of-apps/values.yaml)"

# require_secret <namespace> <name> <consumer>
require_secret() {
  if ! kubectl -n "$1" get secret "$2" >/dev/null 2>&1; then
    fail "Secret $2 is missing in namespace $1 ($3)"
  fi
}

# The cluster has to be at least the Kubernetes version the manifests are rendered and validated against.
min_version="${KUBE_VERSION:-$(sed -n 's/^KUBE_VERSION := //p' Makefile)}"
server_version="$(kubectl version -o json 2>/dev/null | yq -p json '.serverVersion.gitVersion' | sed 's/^v//; s/[^0-9.].*//')"
if [[ -n "$min_version" ]] && [[ "$(printf '%s\n%s\n' "$min_version" "$server_version" | sort -V | head -1)" != "$min_version" ]]; then
  fail "Kubernetes $server_version is older than $min_version, the version the manifests are rendered against"
fi

# Each enabled app's destination namespace exists, or the caller may create it (CreateNamespace=true does).
apps=cluster-configs/app-of-apps/values.yaml
can_create_ns="$(kubectl auth can-i create namespaces 2>/dev/null || true)"
for app in $(yq '.applications | keys | .[]' "$apps"); do
  app_enabled "$app" || continue
  ns="$(yq ".applications.\"$app\".namespace // .namespace" "$apps")"
  if ! kubectl get namespace "$ns" >/dev/null 2>&1 && [[ "$can_create_ns" != yes ]]; then
    fail "namespace $ns ($app) does not exist and this context cannot create namespaces"
  fi
done

# global.mesh defaults to istio, so an environment that does not set it needs Istio's CRDs.
mesh="$(yq '.global.mesh // "istio"' "$values")"
if [[ "$mesh" == istio ]]; then
  for crd in gateways.networking.istio.io virtualservices.networking.istio.io; do
    kubectl get crd "$crd" >/dev/null 2>&1 ||
      fail "global.mesh is istio but CRD $crd is not installed; install Istio or set global.mesh: kubernetes"
  done
fi

# vault.enabled, globally or on any app, needs the Vault Agent Injector's mutating webhook.
if [[ "$(yq '[.global.vault.enabled, .applications[].values.vault.enabled] | any_c(. == true)' "$values")" == true ]]; then
  if ! kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -q vault; then
    fail "vault.enabled is true but no Vault Agent Injector webhook is installed (no MutatingWebhookConfiguration named *vault*)"
  fi
fi

# With global.externalSecrets.enabled, the External Secrets operator creates the declared Secrets from the
# site's store, so its CRD has to be installed and those Secrets need not exist yet.
external_secrets="$(yq '.global.externalSecrets.enabled // false' "$values")"
if [[ "$external_secrets" == true ]]; then
  kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1 ||
    fail "global.externalSecrets.enabled is true but the External Secrets operator's CRD externalsecrets.external-secrets.io is not installed"
  [[ -n "$(yq '.global.externalSecrets.secretStoreRef.name // ""' "$values")" ]] ||
    fail "global.externalSecrets.enabled is true but global.externalSecrets.secretStoreRef.name is empty"
fi
# require_declared_secret <namespace> <name> <consumer>: as require_secret, unless External Secrets makes it.
require_declared_secret() {
  [[ "$external_secrets" == true ]] || require_secret "$@"
}

# A Secret the environment creates itself (create: true) is made by the first sync, so only the
# others have to exist already.
if app_enabled clickhouse-operator &&
  [[ "$(yq '.applications.clickhouse-operator.values.secrets.credentials.create' "$values")" != true ]]; then
  require_declared_secret "$operator_namespace" clickhouse-operator-credentials "clickhouse-operator"
fi
if app_enabled clickhouse &&
  [[ "$(yq '.applications.clickhouse.values.secrets.credentials.create' "$values")" != true ]]; then
  require_declared_secret "$default_namespace" clickhouse-credentials "clickhouse, cerberus, otel-collector"
fi
if app_enabled grafana &&
  [[ "$(yq '.applications.grafana.values.secrets.admin.create' "$values")" != true ]]; then
  require_declared_secret "$default_namespace" grafana-admin "grafana"
fi
if app_enabled otel-collector &&
  [[ "$(yq '.applications.otel-collector.values.collector.auth.enabled' "$values")" == true ]] &&
  [[ "$(yq '.applications.otel-collector.values.secrets.auth.create' "$values")" != true ]]; then
  require_secret "$default_namespace" otel-collector-auth "otel-collector OTLP bearer token"
fi

# An empty storageClassName means the cluster's default StorageClass, so one has to exist.
if app_enabled clickhouse; then
  storage_class="$(app_value clickhouse .clickhouse.storageClassName)"
  if [[ -z "$storage_class" ]]; then
    storage_class="$(yq '.clickhouse.storageClassName // ""' cluster-nodes/clickhouse/values.yaml)"
  fi
  if [[ -z "$storage_class" ]]; then
    if [[ -z "$(kubectl get sc -o name 2>/dev/null)" ]]; then
      fail "no StorageClass is visible and clickhouse.storageClassName is empty, so the ClickHouse volume would stay Pending"
    fi
  elif ! kubectl get sc "$storage_class" >/dev/null 2>&1; then
    fail "StorageClass $storage_class (clickhouse.storageClassName) does not exist"
  fi
fi

if ((failures > 0)); then
  echo "preflight: $failures check(s) failed" >&2
  exit 1
fi
echo "preflight: all checks passed"
