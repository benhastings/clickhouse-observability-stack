#!/usr/bin/env bash
# check-restricted-test.bash: prove check-restricted.bash passes the committed restricted environments, and fails
# a copy of each one's golden render with a clickhouse-operator Application added. No clusterScoped: false
# environment may render one, whoever runs ClickHouse: the shared operator (restricted), a service owner (paas)
# or a Deployment (standalone). Its CRDs, ClusterRole and ClusterRoleBinding are what the project forbids, so a
# leftover one stays OutOfSync forever (docs/runbook.md: A stale child Application).
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/check-restricted-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "check-restricted-test: $1"; exit 1; }

scripts/check-restricted.bash restricted paas standalone >/dev/null || fail "the committed restricted environments do not pass"

for env in restricted paas standalone; do
  rm -rf "$work/golden"
  mkdir -p "$work/golden"
  for each in restricted paas standalone; do cp -r "tests/golden/$each" "$work/golden/$each"; done
  # The clickhouse Application, renamed: an operator child that is otherwise as namespaced as the rest.
  yq ea 'select(.kind == "Application" and .spec.source.helm.releaseName == "clickhouse")
    | .metadata.name = "clickhouse-operator-'"$env"'"
    | .spec.source.path = "cluster-nodes/clickhouse-operator"
    | .spec.source.helm.releaseName = "clickhouse-operator"' \
    "tests/golden/$env/app-of-apps.yaml" >"$work/operator.yaml"
  [[ -s "$work/operator.yaml" ]] || fail "$env: no clickhouse Application to copy"
  { echo "---"; cat "$work/operator.yaml"; } >>"$work/golden/$env/app-of-apps.yaml"
  if out="$(GOLDEN="$work/golden" scripts/check-restricted.bash "$env" 2>&1)"; then
    fail "$env: check-restricted.bash passed an operator Application"
  fi
  grep -q "Application/clickhouse-operator-$env installs the ClickHouse operator" <<<"$out" ||
    fail "$env: no operator Application failure in: $out"
  echo "check-restricted-test: ok, $env with an operator Application is rejected"
done
