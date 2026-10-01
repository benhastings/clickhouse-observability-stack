#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_URL=https://github.com/benhastings/clickhouse-observability-stack.git
errors=0

fail() {
  echo "  $1: $2"
  errors=$((errors + 1))
}

referenced_paths=()
referenced_values=()

check_app() {
  local file=$1
  local name
  name="$(yq '.metadata.name' "$file")"

  [[ "$(yq '.kind' "$file")" == Application ]] || fail "$file" "kind must be Application"
  [[ "$(yq '.metadata.namespace' "$file")" == argocd ]] || fail "$file" "metadata.namespace must be argocd"
  [[ "$(basename "$file" .yaml)" == "$name" ]] || fail "$file" "file name must match metadata.name ($name)"
  [[ "$(yq '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$file")" =~ ^[0-9]+$ ]] ||
    fail "$file" "needs an integer argocd.argoproj.io/sync-wave annotation"
  [[ "$(yq '.metadata.finalizers[] | select(. == "resources-finalizer.argocd.argoproj.io")' "$file")" ]] ||
    fail "$file" "needs the resources-finalizer.argocd.argoproj.io finalizer"
  [[ "$(yq '.spec.syncPolicy.automated.prune' "$file")" == true ]] || fail "$file" "syncPolicy.automated.prune must be true"
  [[ "$(yq '.spec.syncPolicy.automated.selfHeal' "$file")" == true ]] || fail "$file" "syncPolicy.automated.selfHeal must be true"
  [[ "$(yq '.spec.destination.server' "$file")" == https://kubernetes.default.svc ]] ||
    fail "$file" "destination.server must be https://kubernetes.default.svc"

  local sources='[.spec.source, .spec.sources[]] | map(select(. != null))'
  local count
  count="$(yq "$sources | length" "$file")"
  for ((i = 0; i < count; i++)); do
    local src="$sources | .[$i]"

    local url rev chart path ref
    url="$(yq "$src | .repoURL" "$file")"
    rev="$(yq "$src | .targetRevision" "$file")"
    chart="$(yq "$src | .chart // \"\"" "$file")"
    path="$(yq "$src | .path // \"\"" "$file")"
    ref="$(yq "$src | .ref // \"\"" "$file")"

    if [[ -n "$chart" ]]; then
      ((i == 0)) || fail "$file" "chart $chart must be the first source"
      [[ "$rev" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$file" "chart $chart must pin an exact version, got '$rev'"
      while IFS= read -r vf; do
        [[ -z "$vf" ]] && continue
        [[ "$vf" == \$values/* ]] || fail "$file" "value file $vf must come from this repo via \$values/"
        local local_vf=${vf#\$values/}
        [[ -f "$local_vf" ]] || fail "$file" "value file $local_vf does not exist"
        referenced_values+=("$local_vf")
      done < <(yq "$src | .helm.valueFiles[]" "$file")
    else
      [[ "$url" == "$REPO_URL" ]] || fail "$file" "non-chart source must be this repo ($REPO_URL), got $url"
      [[ "$rev" == main ]] || fail "$file" "this repo's sources track targetRevision main, got '$rev'"
      if [[ -n "$path" ]]; then
        [[ -d "$path" ]] || fail "$file" "source path $path does not exist"
        referenced_paths+=("$path")
      elif [[ "$ref" != values ]]; then
        fail "$file" "a source of this repo needs a path or ref: values"
      fi
    fi
  done
}

echo "==> Checking Argo CD Applications"
for file in apps/*.yaml; do
  check_app "$file"
done

[[ "$(yq '.spec.source.path' bootstrap/root-app.yaml)" == apps ]] || fail bootstrap/root-app.yaml "root app must deploy apps/"
[[ "$(yq '.spec.source.repoURL' bootstrap/root-app.yaml)" == "$REPO_URL" ]] || fail bootstrap/root-app.yaml "root app must point at $REPO_URL"

echo "==> Checking for files no Application deploys"
for dir in manifests/*/; do
  dir=${dir%/}
  [[ " ${referenced_paths[*]} " == *" $dir "* ]] || fail "$dir" "no Application in apps/ deploys this directory"
done
for vf in values/*.yaml; do
  [[ " ${referenced_values[*]} " == *" $vf "* ]] || fail "$vf" "no Application in apps/ uses this values file"
done

echo "==> Checking Grafana dashboards are valid JSON"
for file in manifests/grafana-dashboards/*.yaml; do
  while IFS= read -r key; do
    yq ".data[\"$key\"]" "$file" | jq empty 2>/dev/null || fail "$file" "data.$key is not valid JSON"
  done < <(yq '.data | keys | .[]' "$file")
done

if ((errors > 0)); then
  echo "check-apps: $errors problem(s) found"
  exit 1
fi
echo "check-apps: ok"
