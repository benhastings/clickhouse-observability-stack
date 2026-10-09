#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "  $1: $2"
  errors=$((errors + 1))
}

aoa=cluster-configs/app-of-apps

echo "==> Checking cluster-nodes charts"
for dir in cluster-nodes/*/; do
  dir="${dir%/}"
  node="$(basename "$dir")"
  chart="$dir/Chart.yaml"
  [[ "$(yq '.name' "$chart")" == "$node" ]] || fail "$chart" "name must be $node"
  # A node renders the common templates with its own values: its templates/ is a link to them, not a copy.
  [[ -L "$dir/templates" && "$(readlink "$dir/templates")" == ../../helm-templates/common/templates ]] ||
    fail "$dir/templates" "must be a symlink to ../../helm-templates/common/templates"
  [[ "$(yq '.dependencies // [] | length' "$chart")" == 0 ]] || fail "$chart" "must have no dependencies"
  compgen -G "$dir/tests/*_test.yaml" >/dev/null || fail "$dir" "needs at least one helm-unittest suite in tests/"
  [[ "$(yq ".applications.\"$node\"" "$aoa/values.yaml")" != null ]] ||
    fail "$dir" "is not listed under applications in $aoa/values.yaml"
done

echo "==> Checking the app-of-apps application list"
nodes_listed="$(yq '.nodes | sort | .[]' "$aoa/values.yaml")"
nodes_on_disk="$(find cluster-nodes -mindepth 2 -maxdepth 2 -name Chart.yaml -printf '%h\n' | xargs -n1 basename | sort)"
[[ "$nodes_listed" == "$nodes_on_disk" ]] ||
  fail "$aoa/values.yaml" "nodes must list exactly the charts under cluster-nodes/: ${nodes_on_disk//$'\n'/ }"
while IFS= read -r app; do
  [[ -d "cluster-nodes/$app" ]] || fail "$aoa/values.yaml" "application $app has no cluster-nodes/$app chart"
  [[ "$(yq ".applications.\"$app\".syncWave" "$aoa/values.yaml")" =~ ^[0-9]+$ ]] ||
    fail "$aoa/values.yaml" "application $app needs an integer syncWave"
done < <(yq '.applications | keys | .[]' "$aoa/values.yaml")

echo "==> Checking environments"
for overrides in cluster-configs/overrides/values-*.yaml; do
  env="$(basename "$overrides" .yaml)"
  env="${env#values-}"
  bootstrap="$aoa/app-of-apps-$env.yaml"
  [[ "$(yq '.environment' "$overrides")" == "$env" ]] || fail "$overrides" "environment must be $env"
  [[ -f "$bootstrap" ]] || { fail "$overrides" "has no $bootstrap"; continue; }
  [[ "$(yq '.spec.source.helm.valueFiles[0]' "$bootstrap")" == "../overrides/values-$env.yaml" ]] ||
    fail "$bootstrap" "must load ../overrides/values-$env.yaml"
  [[ "$(yq '.spec.source.path' "$bootstrap")" == "$aoa" ]] || fail "$bootstrap" "must deploy $aoa"
  [[ "$(yq '.spec.source.repoURL' "$bootstrap")" == "$(yq '.repoURL' "$overrides")" ]] ||
    fail "$bootstrap" "repoURL must match $overrides"
  [[ "$(yq '.spec.source.targetRevision' "$bootstrap")" == "$(yq '.targetRevision' "$overrides")" ]] ||
    fail "$bootstrap" "targetRevision must match $overrides"
  while IFS= read -r app; do
    [[ "$(yq ".applications.\"$app\"" "$aoa/values.yaml")" != null ]] ||
      fail "$overrides" "overrides application $app, which $aoa/values.yaml does not list"
  done < <(yq '.applications // {} | keys | .[]' "$overrides")
done
for bootstrap in "$aoa"/app-of-apps-*.yaml; do
  env="$(basename "$bootstrap" .yaml)"
  env="${env#app-of-apps-}"
  [[ -f "cluster-configs/overrides/values-$env.yaml" ]] || fail "$bootstrap" "has no cluster-configs/overrides/values-$env.yaml"
done

echo "==> Checking Grafana dashboards are valid JSON"
for file in cluster-nodes/grafana/dashboards/*.json; do
  jq empty "$file" 2>/dev/null || fail "$file" "is not valid JSON"
done

if ((errors > 0)); then
  echo "check-structure: $errors problem(s) found"
  exit 1
fi
echo "check-structure: ok"
