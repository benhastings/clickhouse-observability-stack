#!/usr/bin/env bash
# Checks the current kube context against an environment file before the first sync. Installs nothing.
# Usage: ENV=<env> [KUBE_VERSION=<x.y.z>] scripts/preflight.bash   (or make cluster/preflight ENV=<env>)
#
# It checks the Kubernetes version against KUBE_VERSION (the version the golden files render against),
# each destination namespace (and, with clusterScoped: false, that it exists with its Istio injection label),
# the Secrets the environment does not create, a StorageClass for ClickHouse, Istio's API when global.mesh is
# istio, the Vault injector when vault.enabled is true, and, with global.clickhouseOperator.shared, the
# platform's ClickHouse operator: its CRD, the right to create an installation, and a Ready operator pod.
# With global.clickhouse.external it checks the service contract instead (README: The ClickHouse service
# contract): the CA bundle's ConfigMap and key, and each credential Secret an enabled app reads. It never reads a
# Secret's data, only whether the Secret exists.
#
# First it renders the environment (scripts/render.bash, which fails on a mixed secret mechanism) and prints the
# mechanism each app reads its credentials through, with every record that mechanism has to hold before the first
# sync: Secret names and keys, Vault paths and fields, or External Secrets remote keys and properties
# (scripts/secret-records.bash). It prints names only, never a value. A Helm error in that render stops preflight:
# Argo CD would refuse the same parent, so nothing is applied past it.
#
# Every revision Argo CD would follow has to be immutable, a 40-character commit SHA or a tag: the bootstrap
# Application's targetRevision, values-<env>.yaml's, and any child's own pin. A branch lets children move on while a
# parent that fails to render can no longer change them (docs/runbook.md: Recovering a parent that fails to render).
# PREFLIGHT_REVISION is the revision bootstrap.bash deploys in place of the files' (its <revision>), and
# ALLOW_MUTABLE_REVISION=1 accepts a branch, for a throwaway cluster (make cluster/up, make test/e2e) or the Helm
# path, which follows no revision. It also says whether the render has a clickhouse-operator Application.
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

# The credential records, from the environment's own render.
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT
if ! KUBE_VERSION="${KUBE_VERSION:-$(sed -n 's/^KUBE_VERSION := //p' Makefile)}" scripts/render.bash "$render_dir" "$env_name" >/dev/null 2> >(grep -v "found symbolic link" >&2); then
  echo "preflight: the $env_name app-of-apps does not render (above); Argo CD would refuse the same parent, so fix $values before syncing anything" >&2
  exit 1
fi
if grep -q "^  name: clickhouse-operator-" "$render_dir/$env_name/app-of-apps.yaml" 2>/dev/null; then
  echo "==> The render has a clickhouse-operator Application (with its CRDs and cluster RBAC)"
else
  echo "==> The render has no clickhouse-operator Application"
fi
records="$(scripts/secret-records.bash "$render_dir/$env_name")"
echo "==> Secret mechanism: $(awk '{print $2}' <<<"$records" | sort -u | paste -sd' ' | sed 's/ /, /g') (README: Credentials)"
echo "==> Credential records the environment needs before the first sync (app, mechanism, record):"
while IFS= read -r record; do echo "    $record"; done <<<"$records"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# immutable <revision>: a 40-character commit SHA, or a tag in this checkout.
immutable() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || git show-ref --verify --quiet "refs/tags/$1"
}
bootstrap_file="cluster-configs/app-of-apps/app-of-apps-$env_name.yaml"
revisions=()
if [[ -n "${PREFLIGHT_REVISION:-}" ]]; then
  revisions+=("the deployed revision (bootstrap's <revision>)=$PREFLIGHT_REVISION")
else
  revisions+=("$bootstrap_file spec.source.targetRevision=$(yq '.spec.source.targetRevision // ""' "$bootstrap_file" 2>/dev/null)")
  revisions+=("$values targetRevision=$(yq '.targetRevision // ""' "$values")")
fi
while IFS=$'\t' read -r app revision; do
  [[ -n "$app" ]] && revisions+=("$values applications.$app.targetRevision=$revision")
done < <(yq -r '.applications // {} | to_entries[] | select(.value.targetRevision) | [.key, .value.targetRevision] | @tsv' "$values")
for each in "${revisions[@]}"; do
  where="${each%=*}" revision="${each##*=}"
  if immutable "$revision"; then
    echo "==> Revision: $where is $revision"
  elif [[ "${ALLOW_MUTABLE_REVISION:-}" == 1 ]]; then
    echo "WARN: $where is ${revision:-empty}, which can move; accepted with ALLOW_MUTABLE_REVISION=1" >&2
  else
    fail "$where is ${revision:-empty}, not a commit SHA or a tag: pin it, so children cannot move on while a parent that fails to render cannot change them (docs/runbook.md: Recovering a parent that fails to render), or set ALLOW_MUTABLE_REVISION=1 for a throwaway cluster"
  fi
done

# app_value <app> <yq path under applications.<app>.values>: the environment's value, empty when unset.
app_value() {
  yq ".applications.\"$1\".values$2 // \"\"" "$values"
}

# With global.clickhouseOperator.shared a platform team runs the ClickHouse operator, and the app-of-apps
# renders no clickhouse-operator application.
operator_shared="$(yq '.global.clickhouseOperator.shared // false' "$values")"
# With global.clickhouse.external a service owner runs ClickHouse: no operator, no installation, no volume.
clickhouse_external="$(yq '.global.clickhouse.external // false' "$values")"
# With global.clickhouse.standalone the stack runs ClickHouse itself, without any operator.
clickhouse_standalone="$(yq '.global.clickhouse.standalone // false' "$values")"

app_enabled() {
  [[ "$1" == clickhouse-operator && ("$operator_shared" == true || "$clickhouse_external" == true ||
    "$clickhouse_standalone" == true) ]] && return 1
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
# The namespace label the mesh needs before any pod starts: sidecar injection, or ambient's dataplane mode.
mesh_label=istio-injection=enabled
[[ "$(yq '.global.istio.dataplaneMode // "sidecar"' "$values")" != ambient ]] || mesh_label=istio.io/dataplane-mode=ambient
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
    if [[ "$mesh" == istio && "$(yq -p json ".metadata.labels.\"${mesh_label%%=*}\" // \"\"" <<<"$namespace_json")" != "${mesh_label#*=}" ]]; then
      fail "namespace $ns is not labelled $mesh_label; with clusterScoped: false the stack does not label it, so ask the platform team to"
    fi
  elif kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1; then
    [[ "$mesh" != istio ]] ||
      echo "WARN: cannot read namespace $ns to see its labels; confirm with the platform team that it is labelled $mesh_label" >&2
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
# app_vault <app>: "true" when the app reads its credentials from Vault (its own vault.enabled, else the global one),
# so the Secrets it would otherwise read need not exist: the records preflight listed above are Vault's.
app_vault() {
  yq "[.global.vault.enabled, .applications.\"$1\".values.vault.enabled] | [false] + map(select(. != null)) | .[-1]" "$values"
}
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
if app_enabled clickhouse && [[ "$clickhouse_external" != true && "$(app_vault clickhouse)" != true ]]; then
  for user in admin:"clickhouse schema Job" writer:otel-collector reader:cerberus analyst:"notebooks and jobs"; do
    if [[ "$(yq ".applications.clickhouse.values.secrets.${user%%:*}.create" "$values")" != true ]]; then
      require_declared_secret "$default_namespace" "clickhouse-${user%%:*}" "clickhouse, ${user#*:}"
    fi
  done
fi
# garmr's ClickHouse user exists unless the environment turns clickhouse.garmr off.
if app_enabled clickhouse && [[ "$clickhouse_external" != true && "$(app_vault clickhouse)" != true ]] && [[ "$(yq '.applications.clickhouse.values.clickhouse.garmr.enabled' "$values")" != false ]] &&
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

# An external ClickHouse: the service owner issues each identity, so every Secret an enabled app reads has to exist
# before the first sync, and the platform's CA bundle has to be in the namespace. Only existence is checked.
if [[ "$clickhouse_external" == true ]]; then
  contract="global.clickhouse.external is true (README: The ClickHouse service contract)"
  # ClickHouse and its clients agree on one mechanism (the render refuses otherwise), so on Vault none of these is a
  # Secret.
  if [[ "$(app_vault clickhouse)" != true ]]; then
    if app_enabled clickhouse; then
      require_declared_secret "$default_namespace" clickhouse-admin "$contract: the schema Job's migration identity, otel_admin; or set applications.clickhouse.enabled: false if the service owner applies the schema"
    fi
    if app_enabled otel-collector; then
      require_declared_secret "$default_namespace" clickhouse-writer "$contract: otel-collector, otel_writer"
    fi
    if app_enabled cerberus || app_enabled garmr-sql-adapter; then
      require_declared_secret "$default_namespace" clickhouse-reader "$contract: cerberus and garmr sql-adapter, otel_reader"
    fi
    if app_enabled garmr; then
      require_declared_secret "$default_namespace" clickhouse-garmr "$contract: garmr serve, otel_garmr"
    fi
  fi
  ca_configmap="$(yq '.global.clickhouse.tls.caConfigMap // ""' "$values")"
  ca_key="$(yq '.global.clickhouse.tls.caKey // "ca.crt"' "$values")"
  if [[ -z "$ca_configmap" || -z "$(yq '.global.clickhouse.tls.serverName // ""' "$values")" ]]; then
    fail "$contract, so global.clickhouse.tls.serverName and global.clickhouse.tls.caConfigMap are required"
  elif [[ "$(yq '.global.clickhouse.tls.vault // false' "$values")" == true ]]; then
    : # global.clickhouse.tls.vault: the CA bundle is the Vault field listed above, not a ConfigMap.
  elif ! ca_json="$(kubectl -n "$default_namespace" get configmap "$ca_configmap" -o json 2>/dev/null)"; then
    fail "ConfigMap $ca_configmap (global.clickhouse.tls.caConfigMap) is missing in namespace $default_namespace: ask the platform team for the CA bundle that signed the ClickHouse service's certificate"
  elif [[ "$(yq -p json ".data.\"$ca_key\" // \"\"" <<<"$ca_json")" != *"BEGIN CERTIFICATE"* ]]; then
    fail "ConfigMap $ca_configmap has no PEM certificate under key $ca_key (global.clickhouse.tls.caKey)"
  fi
fi

# A shared operator is not installed by this stack, so it has to be there already: the API serves the
# ClickHouseInstallation kind (checked through discovery, which needs no cluster-wide read of CRDs), this context
# may create one in the stack's namespace, and an operator pod is Ready. A tenant that may not list pods in the
# operator's namespace gets a warning instead: whether it watches the stack's namespace is for the platform team.
if [[ "$operator_shared" == true && "$clickhouse_external" != true ]] && app_enabled clickhouse; then
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
# cluster-scoped, so a tenant that may not read them gets a warning instead. An external ClickHouse needs none.
if app_enabled clickhouse && [[ "$clickhouse_external" != true ]]; then
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
