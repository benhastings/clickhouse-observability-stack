#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION=1.34.0
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo "==> Rendering Helm charts"
for file in apps/*.yaml; do
  name="$(yq '.metadata.name' "$file")"
  chart="$(yq '.spec.sources[0].chart // ""' "$file")"
  [[ -z "$chart" ]] && continue

  url="$(yq '.spec.sources[0].repoURL' "$file")"
  version="$(yq '.spec.sources[0].targetRevision' "$file")"
  release="$(yq '.spec.sources[0].helm.releaseName' "$file")"
  namespace="$(yq '.spec.destination.namespace' "$file")"
  values=()
  while IFS= read -r vf; do
    values+=(-f "${vf#\$values/}")
  done < <(yq '.spec.sources[0].helm.valueFiles[]' "$file")

  if [[ "$url" == http* ]]; then
    ref=(--repo "$url" "$chart")
  else
    ref=("oci://$url/$chart")
  fi

  echo "  $name: $chart $version"
  helm template "$release" "${ref[@]}" --version "$version" --namespace "$namespace" \
    --kube-version "$KUBE_VERSION" "${values[@]}" >"$out/$name.yaml"
done

echo "==> Rendering cluster nodes"
for chart in cluster-nodes/*/; do
  name="$(basename "$chart")"
  echo "  $name"
  helm template "$name" "$chart" --namespace observability --kube-version "$KUBE_VERSION" >"$out/node-$name.yaml"
done

echo "==> Validating rendered charts and plain manifests"
kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" \
  -schema-location default \
  -schema-location "$CRD_CATALOG" \
  "$out" bootstrap/root-app.yaml bootstrap/repositories.yaml apps manifests
