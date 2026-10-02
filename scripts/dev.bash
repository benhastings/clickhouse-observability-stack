#!/usr/bin/env bash
# Run the local stack on kind without Argo CD, straight from the working tree.
#
#   dev.bash up             kind cluster, then every app except demo-load, in sync-wave order
#   dev.bash apply <app>    install or upgrade one app from cluster-nodes/<app>
#   dev.bash remove <app>   uninstall one app
#
# Each app gets the release, namespace and values Argo CD would give it in the
# local environment (see apps.bash). Sync waves become install order: helm
# waits for each app, and for a ClickHouseInstallation to be Completed, before
# the next starts.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash

ENV=local
CLUSTER=clickhouse-obs

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

use_cluster() {
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "This cluster runs Argo CD, which would undo anything installed here."
    echo "Delete it with make cluster/down, then run make dev/up."
    exit 1
  fi
}

apply() {
  local app=$1
  load_app "$work/app-of-apps.yaml" "$app-$ENV" "$work/$app.yaml"
  [[ -n "$app_path" && "$app_path" != null ]] || { echo "unknown app: $app (see cluster-configs/app-of-apps/values.yaml)"; exit 1; }
  echo "==> $app"
  helm upgrade --install "$app_release" "$app_path" --namespace "$app_namespace" --create-namespace \
    -f "$work/$app.yaml" --wait --timeout 10m
  wait_for_clickhouse "$app_release" "$app_namespace"
}

# Argo CD's health check for a ClickHouseInstallation, as a wait: helm can't
# tell when the operator has finished creating ClickHouse.
wait_for_clickhouse() {
  local chi
  kubectl get crd clickhouseinstallations.clickhouse.altinity.com >/dev/null 2>&1 || return 0
  for chi in $(kubectl -n "$2" get clickhouseinstallations -l "app.kubernetes.io/instance=$1" -o name); do
    echo "    waiting for $chi to be Completed"
    kubectl -n "$2" wait "$chi" --for=jsonpath='{.status.status}'=Completed --timeout=10m
  done
}

render_app_of_apps "$ENV" >"$work/app-of-apps.yaml"

case "${1:-}" in
  up)
    if ! kind get clusters | grep -qx "$CLUSTER"; then
      kind create cluster --config kind-config.yaml
    fi
    use_cluster
    while IFS= read -r name; do
      app="${name%"-$ENV"}"
      # Traffic is opt-in here: make dev/load.
      [[ "$app" == demo-load ]] || apply "$app"
    done < <(app_names "$work/app-of-apps.yaml")
    cat <<'MSG'

The stack is up, with no demo traffic. Next:
  make dev/port-forward     Grafana :3000, Cerberus :8081, OTLP :4317/:4318
  make dev/load             start the demo load
  make dev/apply APP=<app>  redeploy one app after editing it
MSG
    ;;
  apply)
    use_cluster
    apply "${2:?usage: dev.bash apply <app>}"
    ;;
  remove)
    use_cluster
    load_app "$work/app-of-apps.yaml" "${2:?usage: dev.bash remove <app>}-$ENV" "$work/values.yaml"
    helm uninstall "$app_release" --namespace "$app_namespace" --wait
    ;;
  *)
    sed -n '2,6p' "$0"
    exit 1
    ;;
esac
