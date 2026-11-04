#!/usr/bin/env bash
# check-quota.bash [<env>...]: for each environment whose values file sets global.quota.requireLimits: true (a
# namespace with a ResourceQuota on CPU and memory), fail when any container in tests/golden/<env>/ lacks a CPU or
# memory request or limit. Init containers, Jobs and CronJobs count, and a pod that Vault injects an agent into
# must carry the agent's four resource annotations. With no <env> it checks every environment that sets the switch.
# GOLDEN overrides the golden directory (tests/golden) and OVERRIDES the overrides directory.
set -euo pipefail
cd "$(dirname "$0")/.."

golden=${GOLDEN:-tests/golden}
overrides_dir=${OVERRIDES:-cluster-configs/overrides}

envs=("$@")
if ((${#envs[@]} == 0)); then
  for overrides in "$overrides_dir"/values-*.yaml; do
    env="$(basename "$overrides" .yaml)"
    env="${env#values-}"
    [[ "$(yq '.global.quota.requireLimits // false' "$overrides")" == true ]] && envs+=("$env")
  done
fi

errors=0
for env in "${envs[@]}"; do
  echo "==> Checking CPU and memory requests and limits for the quota environment $env"
  if [[ ! -d "$golden/$env" ]]; then
    echo "  no $golden/$env to check"
    errors=$((errors + 1))
    continue
  fi
  for file in "$golden/$env"/*.yaml; do
    # shellcheck disable=SC2016 # $object and $a are yq variables
    while IFS=$'\t' read -r object kind name cpu_req mem_req cpu_lim mem_lim; do
      [[ -n "$object" && "$kind" != null ]] || continue
      for pair in "requests.cpu=$cpu_req" "requests.memory=$mem_req" "limits.cpu=$cpu_lim" "limits.memory=$mem_lim"; do
        if [[ "${pair#*=}" == null ]]; then
          echo "  $file: $object $kind $name has no ${pair%%=*}"
          errors=$((errors + 1))
        fi
      done
    done < <(yq ea -r '
      select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "ClickHouseInstallation") |
      (.kind + "/" + .metadata.name) as $object |
      (.spec.template.spec // .spec.jobTemplate.spec.template.spec // .spec.templates.podTemplates[].spec) |
      ((.containers[] | ["container", .]), ((.initContainers // [])[] | ["init container", .])) |
      [$object, .[0], .[1].name, (.[1].resources.requests.cpu // "null"), (.[1].resources.requests.memory // "null"),
       (.[1].resources.limits.cpu // "null"), (.[1].resources.limits.memory // "null")] | @tsv
    ' "$file")
    # shellcheck disable=SC2016 # $object and $a are yq variables
    while IFS=$'\t' read -r object annotation; do
      [[ -n "$object" && "$object" != null && -n "$annotation" ]] || continue
      echo "  $file: $object injects a Vault agent with no $annotation annotation"
      errors=$((errors + 1))
    done < <(yq ea -r '
      select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "ClickHouseInstallation") |
      (.kind + "/" + .metadata.name) as $object |
      (.spec.template // .spec.jobTemplate.spec.template // .spec.templates.podTemplates[]) |
      (.metadata.annotations // {}) as $a |
      select($a["vault.hashicorp.com/agent-inject"] == "true") |
      ["agent-requests-cpu", "agent-requests-mem", "agent-limits-cpu", "agent-limits-mem"][] |
      select($a["vault.hashicorp.com/" + .] == null) |
      [$object, "vault.hashicorp.com/" + .] | @tsv
    ' "$file")
  done
done

if ((errors > 0)); then
  echo "check-quota: $errors problem(s) found"
  exit 1
fi
echo "check-quota: ok"
