#!/usr/bin/env bash
# check-quota-test.bash: prove check-quota.bash passes the committed quota environments, and fails a copy of
# tests/golden/restricted with one container's CPU limit removed, with a Vault-injected pod that has no agent
# resource annotations, and with an init container that has no requests.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/check-quota-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "check-quota-test: $1"; exit 1; }

scripts/check-quota.bash >/dev/null || fail "the committed quota environments do not pass"

expect_failure() {
  local name=$1 expected=$2 out
  if out="$(GOLDEN="$work/golden" scripts/check-quota.bash restricted 2>&1)"; then
    fail "$name: check-quota.bash passed"
  fi
  grep -q "$expected" <<<"$out" || fail "$name: no \"$expected\" in: $out"
  echo "check-quota-test: ok, $name is rejected"
}
reset() {
  rm -rf "$work/golden"
  mkdir -p "$work/golden"
  cp -r tests/golden/restricted "$work/golden/restricted"
}

reset
yq -i '(select(.kind == "Deployment" and .metadata.name == "grafana") | .spec.template.spec.containers[0].resources.limits) |= del(.cpu)' \
  "$work/golden/restricted/grafana.yaml"
expect_failure "a Deployment container without a CPU limit" "grafana container grafana has no limits.cpu"

reset
yq -i '(select(.kind == "Deployment" and .metadata.name == "cerberus") | .spec.template.metadata.annotations["vault.hashicorp.com/agent-inject"]) = "true"' \
  "$work/golden/restricted/cerberus.yaml"
expect_failure "a Vault-injected pod without agent resources" "injects a Vault agent with no vault.hashicorp.com/agent-limits-cpu"

reset
yq -i '(select(.kind == "Deployment" and .metadata.name == "cerberus") | .spec.template.spec.initContainers) = [{"name": "wait", "image": "busybox:1", "resources": {"limits": {"cpu": "10m", "memory": "8Mi"}}}]' \
  "$work/golden/restricted/cerberus.yaml"
expect_failure "an init container without requests" "init container wait has no requests.cpu"

reset
yq -i '(select(.kind == "Deployment" and .metadata.name == "cerberus") | .spec.template.metadata.annotations) += {"vault.hashicorp.com/agent-inject": "true", "vault.hashicorp.com/agent-requests-cpu": "10m", "vault.hashicorp.com/agent-requests-mem": "32Mi", "vault.hashicorp.com/agent-limits-cpu": "50m", "vault.hashicorp.com/agent-limits-mem": "64Mi"}' \
  "$work/golden/restricted/cerberus.yaml"
GOLDEN="$work/golden" scripts/check-quota.bash restricted >/dev/null || fail "a Vault pod with agent resources was rejected"
echo "check-quota-test: ok, a Vault pod with agent resources passes"
