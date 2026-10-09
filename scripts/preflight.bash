#!/usr/bin/env bash
# Checks the current kube context against an environment file before the first sync. Installs nothing.
# Usage: ENV=<env> scripts/preflight.bash   (or make cluster/preflight ENV=<env>)
#
# Later checks, once the keys exist in the chart: the Istio CRDs when global.mesh is istio, and the
# Vault injector webhook when vault.enabled is true.
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

# A Secret the environment creates itself (create: true) is made by the first sync, so only the
# others have to exist already.
if app_enabled clickhouse-operator &&
  [[ "$(yq '.applications.clickhouse-operator.values.secrets.credentials.create' "$values")" != true ]]; then
  require_secret "$operator_namespace" clickhouse-operator-credentials "clickhouse-operator"
fi
if app_enabled clickhouse &&
  [[ "$(yq '.applications.clickhouse.values.secrets.credentials.create' "$values")" != true ]]; then
  require_secret "$default_namespace" clickhouse-credentials "clickhouse, cerberus, otel-collector"
fi
if app_enabled grafana &&
  [[ "$(yq '.applications.grafana.values.secrets.admin.create' "$values")" != true ]]; then
  require_secret "$default_namespace" grafana-admin "grafana"
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
