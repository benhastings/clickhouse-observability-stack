#!/usr/bin/env bash
# check-restricted.bash [<env>...]: the policy for the restricted-namespace profile (README: A restricted
# namespace), over tests/golden/<env>/ and the environment's bootstrap Application. It checks each <env> named,
# which must be restricted, and every environment whose values file sets clusterScoped: false. It fails on:
#   - any kind not known to be namespaced, which includes every cluster-scoped kind (ClusterRole,
#     ClusterRoleBinding, CustomResourceDefinition, Namespace, webhooks, ...)
#   - an Istio Gateway: the profile binds to a Gateway the platform already runs
#   - CreateNamespace=true or managedNamespaceMetadata on an Application
#   - an AppProject whose clusterResourceWhitelist allows anything
#   - an object, or a RoleBinding subject, in a namespace other than its Application's destination
#   - a <service>.<namespace>.svc address in another namespace (the API server, kubernetes.default.svc, aside)
# An unknown kind fails rather than passes: add it to namespaced below once you know it is namespaced.
set -euo pipefail
cd "$(dirname "$0")/.."

golden=${GOLDEN:-tests/golden}
kinds=(
  ConfigMap Secret Service ServiceAccount Deployment StatefulSet DaemonSet Job CronJob PersistentVolumeClaim
  Role RoleBinding NetworkPolicy PodDisruptionBudget HorizontalPodAutoscaler Ingress DestinationRule VirtualService
  ClickHouseInstallation ExternalSecret Application AppProject
)
namespaced=" ${kinds[*]} "

envs=("$@")
for overrides in cluster-configs/overrides/values-*.yaml; do
  env="$(basename "$overrides" .yaml)"
  env="${env#values-}"
  if [[ "$(yq '.clusterScoped' "$overrides")" == false && " ${envs[*]} " != *" $env "* ]]; then
    envs+=("$env")
  fi
done

errors=0
fail() {
  echo "  $1: $2"
  errors=$((errors + 1))
}

for env in "${envs[@]}"; do
  echo "==> Checking the restricted environment $env"
  overrides="cluster-configs/overrides/values-$env.yaml"
  dir="$golden/$env"
  if [[ ! -f "$overrides" || ! -d "$dir" ]]; then
    fail "$env" "no $overrides or no $dir to check"
    continue
  fi
  [[ "$(yq '.clusterScoped' "$overrides")" == false ]] || fail "$overrides" "must set clusterScoped: false"

  for file in "$dir"/*.yaml "cluster-configs/app-of-apps/app-of-apps-$env.yaml"; do
    release="$(basename "$file" .yaml)"
    if [[ "$release" == app-of-apps* ]]; then
      expected=argocd
    else
      expected="$(yq ea "select(.kind == \"Application\" and .spec.source.helm.releaseName == \"$release\")
        | .spec.destination.namespace" "$dir/app-of-apps.yaml")"
      [[ -n "$expected" ]] || { fail "$file" "has no Application in $dir/app-of-apps.yaml"; continue; }
    fi

    while IFS=$'\t' read -r kind name ns create_ns managed_ns whitelist subjects; do
      [[ -n "$kind" ]] || continue
      object="$kind/$name"
      if [[ "$kind" == Gateway ]]; then
        fail "$file" "$object renders a Gateway; bind to an existing one (global.exposure.gateway.name)"
      elif [[ "$namespaced" != *" $kind "* ]]; then
        fail "$file" "$object is cluster-scoped, or a kind not known to be namespaced"
      fi
      [[ "$ns" == null || "$ns" == "$expected" ]] || fail "$file" "$object is in namespace $ns, not $expected"
      [[ "$create_ns" == false ]] || fail "$file" "$object asks Argo CD to create its namespace (CreateNamespace=true)"
      [[ "$managed_ns" == false ]] || fail "$file" "$object manages its namespace's metadata (managedNamespaceMetadata)"
      [[ "$whitelist" == 0 ]] || fail "$file" "$object allows cluster-scoped kinds (clusterResourceWhitelist)"
      for subject_ns in $subjects; do
        [[ "$subject_ns" == "$expected" ]] || fail "$file" "$object binds a subject in namespace $subject_ns"
      done
    done < <(yq ea -r '[
      [.kind, .metadata.name, (.metadata.namespace // "null"),
       ((.spec.syncPolicy.syncOptions // []) | any_c(. == "CreateNamespace=true")),
       (.spec.syncPolicy.managedNamespaceMetadata != null),
       ((.spec.clusterResourceWhitelist // []) | length),
       ([.subjects[]?.namespace | select(. != null)] | join(" "))] | @tsv
      ] | .[]' "$file")

    while IFS= read -r address; do
      target="${address#*.}"
      target="${target%%.*}"
      [[ "$address" == kubernetes.default.svc* || "$target" == "$expected" ]] ||
        fail "$file" "refers to $address, a Service outside namespace $expected"
    done < <(grep -oE '[a-z0-9]([-a-z0-9]*[a-z0-9])?\.[a-z0-9]([-a-z0-9]*[a-z0-9])?\.svc(\.cluster\.local)?' "$file" | sort -u)
  done
done

if ((errors > 0)); then
  echo "check-restricted: $errors problem(s) found"
  exit 1
fi
echo "check-restricted: ok (${envs[*]})"
