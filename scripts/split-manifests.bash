#!/usr/bin/env bash
# split-manifests.bash <rendered-env-dir> <destination>: split one environment rendered by
# `render.bash <dir> <env>` into one file per object, <destination>/<namespace>/<kind>-<name>.yaml.
# A cluster-scoped object goes under the namespace of the application that rendered it, so the tree has one
# directory per destination namespace, and each directory also gets that Namespace. The app-of-apps
# Applications are dropped: they belong to the GitOps path, not to a tree applied as plain manifests.
# <destination> is emptied first.
set -euo pipefail

src=${1:?usage: split-manifests.bash <rendered-env-dir> <destination>}
dest=${2:?usage: split-manifests.bash <rendered-env-dir> <destination>}
[[ -f "$src/app-of-apps.yaml" ]] || { echo "split: $src has no app-of-apps.yaml; render it with render.bash first" >&2; exit 1; }

# A name, namespace or kind becomes a path segment, so it must be a plain DNS-style word: no slash, no
# "..", nothing that could leave the destination.
safe() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" != *..* ]]; }

rm -rf "$dest"
mkdir -p "$dest"
written=0
for stream in "$src"/*.yaml; do
  [[ "$(basename "$stream")" == app-of-apps.yaml ]] && continue
  app="$(basename "$stream" .yaml)"
  app_namespace="$(yq ".spec.destination.namespace" <(yq "select(.kind == \"Application\" and .spec.source.helm.releaseName == \"$app\")" "$src/app-of-apps.yaml"))"
  [[ -n "$app_namespace" && "$app_namespace" != null ]] || { echo "split: no Application releases $app" >&2; exit 1; }
  count="$(yq ea '[.] | length' "$stream")"
  for ((i = 0; i < count; i++)); do
    doc="$(yq "select(documentIndex == $i)" "$stream")"
    kind="$(yq '.kind // ""' <<<"$doc")"
    [[ -z "$kind" || "$kind" == Application ]] && continue
    name="$(yq '.metadata.name // ""' <<<"$doc")"
    namespace="$(yq ".metadata.namespace // \"$app_namespace\"" <<<"$doc")"
    for part in "$kind" "$name" "$namespace"; do
      safe "$part" || { echo "split: refusing to write $namespace/$kind-$name from $stream: \"$part\" is not a plain name" >&2; exit 1; }
    done
    file="$dest/$namespace/$(tr '[:upper:]' '[:lower:]' <<<"$kind")-$name.yaml"
    [[ -e "$file" ]] && { echo "split: two objects would both be written to $file" >&2; exit 1; }
    mkdir -p "$dest/$namespace"
    printf '%s\n' "$doc" >"$file"
    written=$((written + 1))
  done
done
# Each namespace directory also gets its Namespace, so the tree applies to a cluster that has neither.
for dir in "$dest"/*/; do
  ns="$(basename "$dir")"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$ns" >"$dir/namespace-$ns.yaml"
done
echo "split: wrote $written objects under $dest, plus a Namespace per directory"
