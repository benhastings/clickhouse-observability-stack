#!/usr/bin/env bash
# Create a local kind cluster, install Argo CD, and hand everything else to
# the app-of-apps (bootstrap/root-app.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=clickhouse-obs
ARGOCD_CHART_VERSION=10.9.2

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f bootstrap/argocd-values.yaml --wait --timeout 10m

echo "==> Registering the Cerberus OCI chart repository and the root app"
kubectl apply -f bootstrap/repositories.yaml
kubectl apply -f bootstrap/root-app.yaml

cat <<'MSG'

Argo CD is now syncing the stack. Watch progress with:
  kubectl -n argocd get applications -w
All apps should reach Synced / Healthy within a few minutes. Then run:
  scripts/port-forward.sh
MSG
