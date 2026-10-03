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

yq '{"global": (.global // {})} * (.applications // {}
  | del(.["clickhouse-operator"])
  | with_entries(.value = ((.value.values // {}) * (.value | pick(["enabled"])))))' \
  "$overrides" >"$out/stack.yaml"

yq '{"global": (.global // {})} * (.applications."clickhouse-operator".values // {})' \
  "$overrides" >"$out/clickhouse-operator.yaml"
