#!/usr/bin/env bash
# restart.bash <app>: roll every Deployment and DaemonSet of one app, in its namespace from the
# application list. For a Secret that changed where the chart can't see it, such as a rotated Vault
# secret; a Secret in the cluster can roll pods by itself with deployment.reloader.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:?usage: restart.bash <app>, one of the keys under applications in cluster-configs/app-of-apps/values.yaml}
values=cluster-configs/app-of-apps/values.yaml
if [[ "$(yq ".applications | has(\"$app\")" "$values")" != true ]]; then
  echo "restart: no application $app in $values" >&2
  exit 1
fi
namespace="$(yq ".applications.\"$app\".namespace // .namespace" "$values")"

restarted=0
for kind in deployment daemonset; do
  for name in $(kubectl -n "$namespace" get "$kind" -l "app.kubernetes.io/instance=$app" -o name); do
    kubectl -n "$namespace" rollout restart "$name"
    restarted=$((restarted + 1))
  done
done
if ((restarted == 0)); then
  echo "restart: $app has no Deployment or DaemonSet in namespace $namespace" >&2
  exit 1
fi
