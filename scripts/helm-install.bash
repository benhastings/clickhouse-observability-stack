#!/usr/bin/env bash
# helm-install.bash install|uninstall <env>: the Helm path, without Argo CD, against the current kube
# context. Helm has no sync waves, so install is two releases in order:
#   1. clickhouse-operator in its namespace, which installs the operator's CRDs from its crds/ directory
#   2. a wait until the ClickHouseInstallation CRD is Established
#   3. stack, the umbrella chart, in the default namespace: ClickHouse, Cerberus, the collector, Grafana and,
#      when the environment enables it, the demo load
# It runs make cluster/preflight's checks first and stops if they fail; it never creates Secrets or
# passwords (on kind, make cluster/up and make dev/up do). uninstall removes both releases and leaves the
# CRDs and namespaces in place.
#
# Helm installs a chart's crds/ on the first install only and never upgrades them. After an operator bump,
# apply the new release's CRDs yourself: kubectl apply -f cluster-nodes/clickhouse-operator/crds/
set -euo pipefail
cd "$(dirname "$0")/.."

action=${1:?usage: helm-install.bash install|uninstall <env>}
env=${2:?usage: helm-install.bash install|uninstall <env>}
out=${HELM_OUT:-dist/helm}/$env
apps=cluster-configs/app-of-apps/values.yaml
operator_ns="$(yq '.applications.clickhouse-operator.namespace' "$apps")"
stack_ns="$(yq '.namespace' "$apps")"
crd=clickhouseinstallations.clickhouse.altinity.com

case "$action" in
  install)
    ENV="$env" scripts/preflight.bash
    scripts/values-for-helm.bash "$env" "$out"
    # Under Istio the namespaces need the injection label before any pod starts; Argo CD sets it through
    # managedNamespaceMetadata, so the Helm path sets it here.
    if [[ "$(yq '.global.mesh // "istio"' "cluster-configs/overrides/values-$env.yaml")" == istio ]]; then
      for ns in "$operator_ns" "$stack_ns"; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl label namespace "$ns" istio-injection=enabled --overwrite >/dev/null
      done
    fi
    echo "==> Installing clickhouse-operator into $operator_ns"
    helm upgrade --install clickhouse-operator cluster-nodes/clickhouse-operator \
      --namespace "$operator_ns" --create-namespace -f "$out/clickhouse-operator.yaml" --wait --timeout 5m
    echo "==> Waiting for CRD $crd"
    kubectl wait --for=condition=Established "crd/$crd" --timeout=120s
    echo "==> Installing stack into $stack_ns"
    helm upgrade --install stack cluster-configs/stack \
      --namespace "$stack_ns" --create-namespace -f "$out/stack.yaml" --timeout 10m
    echo "Installed. ClickHouse starts once the operator reconciles the installation:"
    echo "  kubectl -n $stack_ns get chi,pods"
    ;;
  uninstall)
    helm uninstall stack --namespace "$stack_ns" --ignore-not-found
    helm uninstall clickhouse-operator --namespace "$operator_ns" --ignore-not-found
    echo "Left in place: the operator's CRDs (kubectl get crd | grep altinity) and the namespaces"
    echo "$operator_ns and $stack_ns, including the Secrets and the ClickHouse volume claims in them."
    ;;
  *)
    echo "usage: helm-install.bash install|uninstall <env>" >&2
    exit 2
    ;;
esac
