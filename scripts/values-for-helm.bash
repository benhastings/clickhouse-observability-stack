#!/usr/bin/env bash
# values-for-helm.bash <env> <out-dir>: converts cluster-configs/overrides/values-<env>.yaml,
# the Argo CD shape, into values for a Helm install:
#   <out-dir>/stack.yaml                for the cluster-configs/stack umbrella chart
#   <out-dir>/clickhouse-operator.yaml  for cluster-nodes/clickhouse-operator, its own release
# applications.<app>.values becomes <app>:, and applications.<app>.enabled: false becomes
# <app>.enabled: false. The operator file gets global merged with its values, as Argo CD does.
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: values-for-helm.bash <env> <out-dir>}
out=${2:?usage: values-for-helm.bash <env> <out-dir>}
overrides="cluster-configs/overrides/values-$env.yaml"
[[ -f "$overrides" ]] || { echo "values-for-helm: no $overrides" >&2; exit 1; }
mkdir -p "$out"

# The app-of-apps chart's own defaults come first, as Argo CD would apply them: each application's enabled flag
# (demo-load is off unless an environment turns it on), and global.labels.environment set to the environment's name.
merged="$out/merged.yaml"
yq ea 'select(fileIndex == 0) * select(fileIndex == 1)
  | .global.labels.environment = (.global.labels.environment // .environment)' \
  cluster-configs/app-of-apps/values.yaml "$overrides" >"$merged"

yq '{"global": (.global // {})} * (.applications // {}
  | del(.["clickhouse-operator"])
  | with_entries(.value = ((.value.values // {}) * (.value | pick(["enabled"])))))' \
  "$merged" >"$out/stack.yaml"

yq '{"global": (.global // {})} * (.applications."clickhouse-operator".values // {})' \
  "$merged" >"$out/clickhouse-operator.yaml"
rm -f "$merged"
