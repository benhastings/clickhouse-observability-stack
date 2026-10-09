#!/usr/bin/env bash
# bootstrap.bash <env> [<revision>]: hand the current kube context to Argo CD for one environment.
#   1. make cluster/preflight's checks, which stop on a missing Secret before anything is applied; it never
#      creates passwords (on kind, make cluster/up does that first)
#   2. Argo CD, with cluster-configs/argocd/values.yaml (the child-Application and ClickHouseInstallation
#      health checks), unless an argocd-server is already running, in which case it is left alone
#   3. the environment's AppProject, unless it sets projectCreate: false, then app-of-apps-<env>.yaml
# A <revision> deploys that commit or branch instead of the environment's targetRevision; never commit that.
# EXTRA_VALUES=<file> merges that file over the environment's values in the bootstrap Application (the
# MESH=istio kind profile uses it); never for a real cluster, whose values belong in its environment file.
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: bootstrap.bash <env> [<revision>]}
revision=${2:-}
values="cluster-configs/overrides/values-$env.yaml"
bootstrap="cluster-configs/app-of-apps/app-of-apps-$env.yaml"
ARGOCD_CHART_VERSION=10.9.2

[[ -f "$bootstrap" ]] || { echo "bootstrap: no $bootstrap; make env/new NAME=$env writes one" >&2; exit 2; }

ENV="$env" scripts/preflight.bash

if kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  echo "==> Argo CD is already running; leaving it as it is"
else
  echo "==> Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
  helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    -f cluster-configs/argocd/values.yaml --wait --timeout 10m
fi

# The bootstrap Application belongs to the project the chart renders, and Argo CD will not sync an
# Application whose project does not exist yet.
if [[ "$(yq '.projectCreate // true' "$values")" != false ]]; then
  echo "==> Applying the $env AppProject"
  helm template app-of-apps cluster-configs/app-of-apps --namespace argocd \
    -f "$values" --show-only templates/app-project.yaml | kubectl apply -f -
fi

echo "==> Applying the $env app-of-apps${revision:+ at $revision}${EXTRA_VALUES:+ with $EXTRA_VALUES}"
application="$(cat "$bootstrap")"
if [[ -n "$revision" ]]; then
  application="$(REVISION="$revision" yq '.spec.source.targetRevision = strenv(REVISION) |
    .spec.source.helm.valuesObject.targetRevision = strenv(REVISION)' <<<"$application")"
fi
if [[ -n "${EXTRA_VALUES:-}" ]]; then
  application="$(yq ea 'select(fileIndex == 0) * {"spec": {"source": {"helm": {"valuesObject": select(fileIndex == 1)}}}}' \
    <(printf '%s\n' "$application") "$EXTRA_VALUES")"
fi
kubectl apply -f - <<<"$application"

cat <<MSG

Argo CD is now syncing $env. Watch progress with:
  kubectl -n argocd get applications -w
MSG
