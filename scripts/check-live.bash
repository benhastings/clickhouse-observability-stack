#!/usr/bin/env bash
# check-live.bash <env> [<applications.json>]: read-only. Report drift between the Argo CD Applications running
# in the cluster and what this checkout renders for <env> (README: Checking a live cluster for drift). For the
# parent app-of-apps-<env> and every child it prints the repo, path (or chart) and revision Argo CD runs, then
# compares them with the checkout:
#   - repoURL, targetRevision, path or chart, release name and destination namespace
#   - the live valuesObject against a fresh render of values-<env>.yaml, key by key
#   - an Application the render expects and the cluster lacks, or the reverse
# It exits 1 on any drift. It only reads: `kubectl get applications` (or <applications.json>, a
# `kubectl get applications -o json` list, which is how tests/live is tested offline) and `helm template`.
# The top-level repoURL and targetRevision of values-<env>.yaml are the revisions a release is meant to carry;
# a child whose live revision differs from them is drift unless the environment file pins that child itself.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash

env=${1:?usage: check-live.bash <env> [<applications.json>]}
input=${2:-}
overrides="cluster-configs/overrides/values-$env.yaml"
parent_file="cluster-configs/app-of-apps/app-of-apps-$env.yaml"
for f in "$overrides" "$parent_file"; do
  [[ -f "$f" ]] || { echo "check-live: no $f; is $env an environment?" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "$input" ]]; then
  cp "$input" "$work/live.json"
else
  kubectl -n argocd get applications -o json >"$work/live.json"
fi
kube_args=()
[[ -n "${KUBE_VERSION:-}" ]] && kube_args=(--kube-version "$KUBE_VERSION")
render_app_of_apps "$env" "${kube_args[@]}" >"$work/render.yaml"
yq ea -o=json '[select(.kind == "Application")]' "$work/render.yaml" >"$work/expected.json"
yq -o=json '[.]' "$parent_file" >"$work/parent.json"

echo "environment $env: values-$env.yaml says repoURL $(yq '.repoURL' "$overrides"), targetRevision $(yq '.targetRevision' "$overrides")"

# The fields Argo CD acts on, one record per Application. A multi-source Application reports its first source.
jq -n -S --slurpfile live "$work/live.json" --slurpfile expected "$work/expected.json" --slurpfile parent "$work/parent.json" '
  def src: (.spec.source // .spec.sources[0] // {});
  def rec: {
    repo: src.repoURL, revision: src.targetRevision, path: (src.path // null), chart: (src.chart // null),
    release: (src.helm.releaseName // null), namespace: .spec.destination.namespace,
    values: (src.helm.valuesObject // {})
  };
  def index: map({key: .metadata.name, value: rec}) | from_entries;
  ($live[0] | if type == "array" then . else .items end) as $items
  | ($expected[0] + $parent[0]) as $want
  | ($want | map(.metadata.name)) as $names
  | ($items | map(select((.metadata.name | IN($names[]))
      or (.metadata.labels["app.kubernetes.io/part-of"] == "clickhouse-observability-stack"
          and .metadata.labels.environment == $want[0].metadata.labels.environment)))) as $have
  | {want: ($want | index), have: ($have | index)}' >"$work/pair.json"

drift=0
mapfile -t names < <(jq -r '(.want + .have) | keys[]' "$work/pair.json")
for name in "${names[@]}"; do
  jq -e --arg n "$name" '.want[$n] and .have[$n]' "$work/pair.json" >/dev/null || {
    if jq -e --arg n "$name" '.want[$n]' "$work/pair.json" >/dev/null; then
      echo "DRIFT $name: the environment renders it, the cluster has no such Application"
    else
      echo "DRIFT $name: the cluster runs it, the environment no longer renders it"
    fi
    drift=1
    continue
  }
  jq -r --arg n "$name" '.have[$n] | "\($n): \(.repo) \(.path // .chart) @ \(.revision)"' "$work/pair.json"
  while IFS= read -r line; do
    echo "DRIFT $name: $line"
    drift=1
  done < <(jq -r --arg n "$name" '
    .want[$n] as $w | .have[$n] as $h
    | ["repo", "revision", "path", "chart", "release", "namespace"][] as $k
    | select($w[$k] != $h[$k])
    | "\($k) is \($h[$k] // "unset") live, \($w[$k] // "unset") rendered"' "$work/pair.json")
  if ! jq -e --arg n "$name" '.want[$n].values == .have[$n].values' "$work/pair.json" >/dev/null; then
    jq --arg n "$name" '.want[$n].values' "$work/pair.json" >"$work/want-values.json"
    jq --arg n "$name" '.have[$n].values' "$work/pair.json" >"$work/have-values.json"
    echo "DRIFT $name: valuesObject differs (- rendered, + live):"
    diff -u --label rendered --label live "$work/want-values.json" "$work/have-values.json" | tail -n +3 | sed 's/^/    /' || true
    drift=1
  fi
done

if ((drift)); then
  echo "check-live: $env has drifted from the checkout; the lines above name what differs" >&2
  exit 1
fi
echo "check-live: no drift, ${#names[@]} Applications match a fresh render of $env"
