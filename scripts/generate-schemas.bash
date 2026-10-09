#!/usr/bin/env bash
# generate-schemas.bash [<out-root>]: write values.schema.json for every chart that renders through common
# (cluster-nodes/* and the common fixture), from helm-templates/common/schema/node.schema.yaml plus the
# chart's own values.schema.extra.yaml, and for the app-of-apps chart from its schema/ source. helm validates
# a chart's values against values.schema.json on every render. With <out-root>, the files are written under
# it at the same relative paths instead, for make check/schema to compare. It also regenerates the values
# table in helm-templates/common/README.md from the common schema's descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-.}

common=helm-templates/common/schema/node.schema.yaml
for chart in cluster-nodes/* tests/charts/common-fixture; do
  extra="$chart/values.schema.extra.yaml"
  mkdir -p "$out/$chart"
  if [[ -f "$extra" ]]; then
    yq ea -o json -I 2 'select(fileIndex == 0) *+ select(fileIndex == 1)' \
      "$common" "$extra" >"$out/$chart/values.schema.json"
  else
    yq -o json -I 2 '.' "$common" >"$out/$chart/values.schema.json"
  fi
done
mkdir -p "$out/cluster-configs/app-of-apps"
yq -o json -I 2 '.' cluster-configs/app-of-apps/schema/values.schema.yaml >"$out/cluster-configs/app-of-apps/values.schema.json"

# The values table in helm-templates/common/README.md is generated from the same schema. make check/schema
# passes --check through CHECK_REFERENCE.
yq -o json -I 2 '.' "$common" >"$out/node.schema.json.tmp"
mkdir -p "$out/helm-templates/common"
[[ "$out" == . ]] || cp helm-templates/common/README.md "$out/helm-templates/common/README.md"
python3 scripts/values-reference.py "$out/node.schema.json.tmp" "$out/helm-templates/common/README.md"
rm -f "$out/node.schema.json.tmp"
