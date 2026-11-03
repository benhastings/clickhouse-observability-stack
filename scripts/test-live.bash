#!/usr/bin/env bash
# test-live.bash: prove check-live.bash reports drift, offline. The "live" Applications are the fresh render of
# local as a `kubectl get applications -o json` list, so no drift is the baseline and each case then changes one thing.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
env=local
{ render_app_of_apps "$env"; yq ea -N '.' cluster-configs/app-of-apps/app-of-apps-$env.yaml | sed '1i ---'; } >"$work/all.yaml"
yq ea -o=json '[select(.kind == "Application")] | {"items": .}' "$work/all.yaml" >"$work/live.json"

fail=0
expect() { # expect <name> <rc> <output-pattern> <json>
  local rc=0 out
  out="$(scripts/check-live.bash "$env" "$4" 2>&1)" || rc=$?
  if [[ "$rc" != "$2" ]] || ! grep -q -- "$3" <<<"$out"; then
    echo "test-live: $1: want exit $2 and /$3/, got exit $rc:" >&2
    echo "$out" >&2
    fail=1
  else
    echo "test-live: $1: ok"
  fi
}
mutate() { jq "$1" "$work/live.json" >"$work/mutated.json"; }

expect "a render matches itself" 0 'no drift' "$work/live.json"
mutate '(.items[] | select(.metadata.name == "cerberus-local") | .spec.source.targetRevision) = "feature"'
expect "a child on another revision" 1 'DRIFT cerberus-local: revision is feature live, main rendered' "$work/mutated.json"
mutate '(.items[] | select(.metadata.name == "app-of-apps-local") | .spec.source.targetRevision) = "v1.2.3"'
expect "the parent on another revision" 1 'DRIFT app-of-apps-local: revision is v1.2.3' "$work/mutated.json"
mutate '(.items[] | select(.metadata.name == "grafana-local") | .spec.source.helm.valuesObject.global.retention.logs) = 1'
expect "a changed valuesObject" 1 'DRIFT grafana-local: valuesObject differs' "$work/mutated.json"
mutate 'del(.items[] | select(.metadata.name == "vmalert-local"))'
expect "a missing Application" 1 'DRIFT vmalert-local: the environment renders it' "$work/mutated.json"
mutate '.items += [(.items[0] | .metadata.name = "stray-local")]'
expect "an extra Application" 1 'DRIFT stray-local: the cluster runs it' "$work/mutated.json"
mutate '.items |= map(.status = {sync: {status: "Synced"}} | .metadata.resourceVersion = "9")'
expect "status and metadata are ignored" 0 'no drift' "$work/mutated.json"
exit "$fail"
