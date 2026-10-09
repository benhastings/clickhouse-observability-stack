#!/usr/bin/env bash
# Create a local kind cluster and its Secrets with random passwords, then bootstrap the local
# environment onto it (scripts/bootstrap.bash: Argo CD and the app-of-apps-local.yaml).
# Pass a git revision to deploy that commit or branch instead of main. MESH=istio runs the stack in Istio.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/local-secrets.bash
source scripts/local-secrets.bash

REVISION=${1:-}
CLUSTER=clickhouse-obs

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

create_local_secrets
# MESH=istio installs Istio first and deploys local with the mesh, and exposure through its gateway, on.
if [[ "${MESH:-kubernetes}" == istio ]]; then
  scripts/kind-istio.bash
  EXTRA_VALUES=tests/mesh/local-istio.values.yaml scripts/bootstrap.bash local "$REVISION"
else
  scripts/bootstrap.bash local "$REVISION"
fi

cat <<'MSG'
All apps should reach Synced / Healthy within a few minutes. Then run:
  make cluster/port-forward
MSG
