#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash

# render.bash <output-dir> [<env>]: render every node as Argo CD would deploy it, one YAML stream per
# application under <output-dir>/<env>/. With no <env> it renders every environment without CRDs, which is
# tests/golden. With an <env> it renders only that one and includes each chart's CRDs, so the output can be
# applied to a cluster on its own (see scripts/split-manifests.bash).
KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}
out=${1:?usage: render.bash <output-dir> [<env>]}
only=${2:-}

crds=()
if [[ -n "$only" ]]; then
  if [[ ! -f "cluster-configs/overrides/values-$only.yaml" ]]; then
    echo "render: no environment $only (cluster-configs/overrides/values-$only.yaml)" >&2
    exit 1
  fi
  crds=(--include-crds)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for overrides in cluster-configs/overrides/values-*.yaml; do
  env="$(basename "$overrides" .yaml)"
  env="${env#values-}"
  [[ -n "$only" && "$env" != "$only" ]] && continue
  mkdir -p "$out/$env"

  render_app_of_apps "$env" --kube-version "$KUBE_VERSION" >"$out/$env/app-of-apps.yaml"

  while IFS= read -r app; do
    load_app "$out/$env/app-of-apps.yaml" "$app" "$work/values.yaml"
    helm template "$app_release" "$app_path" --namespace "$app_namespace" --kube-version "$KUBE_VERSION" \
      "${crds[@]}" -f "$work/values.yaml" >"$out/$env/$app_release.yaml"
  done < <(app_names "$out/$env/app-of-apps.yaml")
done
