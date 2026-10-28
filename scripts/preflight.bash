#!/usr/bin/env bash
# Checks the current kube context against an environment file before the first sync. Installs nothing.
# Usage: ENV=<env> [KUBE_VERSION=<x.y.z>] scripts/preflight.bash   (or make cluster/preflight ENV=<env>)
#
# It checks the Kubernetes version against KUBE_VERSION (the version the golden files render against),
# each destination namespace (and, with clusterScoped: false, that it exists with its Istio injection label),
# the Secrets the environment does not create, a StorageClass for ClickHouse, Istio's API when global.mesh is
# istio, the Vault injector when vault.enabled is true, and, with global.clickhouseOperator.shared, the
# platform's ClickHouse operator: its CRD, the right to create an installation, and a Ready operator pod.
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

# With global.clickhouseOperator.shared a platform team runs the ClickHouse operator, and the app-of-apps
# renders no clickhouse-operator application.
operator_shared="$(yq '.global.clickhouseOperator.shared // false' "$values")"

app_enabled() {
  [[ "$1" == clickhouse-operator && "$operator_shared" == true ]] && return 1
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

mesh="$(yq '.global.mesh // "istio"' "$values")"
# clusterScoped: false is the restricted-namespace profile: nothing creates or labels a namespace, so each one
# has to exist already, labelled for Istio injection when the mesh is istio. A tenant often may not read
# Namespace objects, so a namespace it cannot read is found through its default ServiceAccount instead, and its
# labels are then for the platform team to confirm.
restricted=false
[[ "$(yq '.clusterScoped' "$values")" == false ]] && restricted=true

# Each enabled app's destination namespace exists, or the caller may create it (CreateNamespace=true does).
apps=cluster-configs/app-of-apps/values.yaml
can_create_ns="$(kubectl auth can-i create namespaces 2>/dev/null || true)"
for ns in $(for app in $(yq '.applications | keys | .[]' "$apps"); do
  app_enabled "$app" && yq ".applications.\"$app\".namespace // .namespace" "$apps"
done | sort -u); do
  if [[ "$restricted" != true ]]; then
    if ! kubectl get namespace "$ns" >/dev/null 2>&1 && [[ "$can_create_ns" != yes ]]; then
      fail "namespace $ns does not exist and this context cannot create namespaces"
    fi
  elif namespace_json="$(kubectl get namespace "$ns" -o json 2>/dev/null)"; then
    if [[ "$mesh" == istio && "$(yq -p json '.metadata.labels."istio-injection" // ""' <<<"$namespace_json")" != enabled ]]; then
      fail "namespace $ns is not labelled istio-injection=enabled; with clusterScoped: false the stack does not label it, so ask the platform team to"
    fi
  elif kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1; then
    [[ "$mesh" != istio ]] ||
      echo "WARN: cannot read namespace $ns to see its labels; confirm with the platform team that it is labelled istio-injection=enabled" >&2
  else
    fail "namespace $ns does not exist, or this context cannot use it; with clusterScoped: false the platform team creates it"
  fi
done

# global.mesh defaults to istio, so an environment that does not set it needs Istio's API (checked through
# discovery, which needs no cluster-wide read of CRDs).
if [[ "$mesh" == istio ]]; then
  istio_api="$(kubectl get --raw /apis/networking.istio.io/v1 2>/dev/null || echo '{}')"
  for resource in gateways virtualservices; do
    yq -p json -e ".resources[] | select(.name == \"$resource\")" <<<"$istio_api" >/dev/null 2>&1 ||
      fail "global.mesh is istio but the cluster does not serve $resource.networking.istio.io/v1; install Istio or set global.mesh: kubernetes"
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
if app_enabled clickhouse; then
  for user in admin:"clickhouse schema Job" writer:otel-collector reader:cerberus analyst:"notebooks and jobs"; do
    if [[ "$(yq ".applications.clickhouse.values.secrets.${user%%:*}.create" "$values")" != true ]]; then
      require_declared_secret "$default_namespace" "clickhouse-${user%%:*}" "clickhouse, ${user#*:}"
    fi
  done
fi
# garmr's ClickHouse user exists unless the environment turns clickhouse.garmr off.
if app_enabled clickhouse && [[ "$(yq '.applications.clickhouse.values.clickhouse.garmr.enabled' "$values")" != false ]] &&
  [[ "$(yq '.applications.clickhouse.values.secrets.garmr.create' "$values")" != true ]]; then
  require_declared_secret "$default_namespace" clickhouse-garmr "clickhouse, garmr serve"
fi
# With vault.enabled for Grafana (its own value, else the global one), its admin login and OAuth client
# secret come from Vault, not from Secrets.
grafana_vault="$(yq '[.global.vault.enabled, .applications.grafana.values.vault.enabled] | [false] + map(select(. != null)) | .[-1]' "$values")"
grafana_oauth_secret="$(app_value grafana .deployment.containers.grafana.secretEnv.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET.secret)"
if app_enabled grafana && [[ "$grafana_vault" != true ]] &&
  [[ "$(yq '.applications.grafana.values.secrets.admin.create' "$values")" != true ]]; then
  require_declared_secret "$default_namespace" grafana-admin "grafana"
fi
if app_enabled grafana && [[ "$grafana_vault" != true && -n "$grafana_oauth_secret" ]]; then
  require_secret "$default_namespace" "$grafana_oauth_secret" "grafana, OAuth client secret"
fi
if app_enabled otel-collector &&
  [[ "$(yq '.applications.otel-collector.values.collector.auth.enabled' "$values")" == true ]] &&
  [[ "$(yq '.applications.otel-collector.values.secrets.auth.create' "$values")" != true ]]; then
  require_secret "$default_namespace" otel-collector-auth "otel-collector OTLP bearer token"
fi

# A shared operator is not installed by this stack, so it has to be there already: the API serves the
# ClickHouseInstallation kind (checked through discovery, which needs no cluster-wide read of CRDs), this context
# may create one in the stack's namespace, and an operator pod is Ready. A tenant that may not list pods in the
# operator's namespace gets a warning instead: whether it watches the stack's namespace is for the platform team.
if [[ "$operator_shared" == true ]] && app_enabled clickhouse; then
  shared_hint="global.clickhouseOperator.shared is true, so the stack does not install the Altinity ClickHouse operator"
  if ! kubectl get --raw /apis/clickhouse.altinity.com/v1 2>/dev/null |
    yq -p json -e '.resources[] | select(.name == "clickhouseinstallations")' >/dev/null 2>&1; then
    fail "$shared_hint, but the cluster does not serve ClickHouseInstallation (clickhouse.altinity.com/v1): ask the platform team to install the operator and its CRD clickhouseinstallations.clickhouse.altinity.com, or set global.clickhouseOperator.shared: false to install them with the stack"
  elif [[ "$(kubectl auth can-i create clickhouseinstallations.clickhouse.altinity.com -n "$default_namespace" 2>/dev/null || true)" != yes ]]; then
    fail "$shared_hint, but this context cannot create a ClickHouseInstallation in namespace $default_namespace: ask the platform team for create, update, patch and delete on clickhouseinstallations.clickhouse.altinity.com there"
  fi
  shared_ns="$(yq '.global.networkPolicy.namespaces.operator // "clickhouse-operator"' "$values")"
  shared_selector="$(yq '.global.clickhouseOperator.podLabels // {"app.kubernetes.io/name": "clickhouse-operator"} | to_entries | map(.key + "=" + .value) | join(",")' "$values")"
  if ! shared_pods="$(kubectl -n "$shared_ns" get pods -l "$shared_selector" -o json 2>/dev/null)"; then
    echo "WARN: cannot list pods in namespace $shared_ns to see the shared ClickHouse operator ($shared_selector); confirm with the platform team that it runs and watches namespace $default_namespace" >&2
  elif [[ "$(yq -p json '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length' <<<"$shared_pods")" == 0 ]]; then
    fail "$shared_hint, but no Ready pod matches $shared_selector in namespace $shared_ns: set global.networkPolicy.namespaces.operator and global.clickhouseOperator.podLabels to where the platform's operator runs, or ask the platform team to start it"
  fi
fi

# An empty storageClassName means the cluster's default StorageClass, so one has to exist. StorageClasses are
# cluster-scoped, so a tenant that may not read them gets a warning instead.
if app_enabled clickhouse; then
  storage_class="$(app_value clickhouse .clickhouse.storageClassName)"
  if [[ -z "$storage_class" ]]; then
    storage_class="$(yq '.clickhouse.storageClassName // ""' cluster-nodes/clickhouse/values.yaml)"
  fi
  if [[ "$(kubectl auth can-i get storageclasses 2>/dev/null || true)" != yes ]]; then
    echo "WARN: this context cannot read StorageClasses; confirm with the platform team that ${storage_class:-a default StorageClass} exists for the ClickHouse volume" >&2
  elif [[ -z "$storage_class" ]]; then
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
