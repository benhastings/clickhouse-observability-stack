#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash

KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}
out=${1:?usage: render.bash <output-dir>}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for overrides in cluster-configs/overrides/values-*.yaml; do
  env="$(basename "$overrides" .yaml)"
  env="${env#values-}"
  mkdir -p "$out/$env"

  render_app_of_apps "$env" --kube-version "$KUBE_VERSION" >"$out/$env/app-of-apps.yaml"

  while IFS= read -r app; do
    load_app "$out/$env/app-of-apps.yaml" "$app" "$work/values.yaml"
    helm template "$app_release" "$app_path" --namespace "$app_namespace" --kube-version "$KUBE_VERSION" \
      -f "$work/values.yaml" >"$out/$env/$app_release.yaml"
  done < <(app_names "$out/$env/app-of-apps.yaml")
done
