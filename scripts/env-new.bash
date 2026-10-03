#!/usr/bin/env bash
# Writes a commented skeleton for a new environment: values-<NAME>.yaml and app-of-apps-<NAME>.yaml.
# Usage: NAME=<env> [FORCE=1] scripts/env-new.bash   (or make env/new NAME=<env> [FORCE=1])
set -euo pipefail
cd "$(dirname "$0")/.."

name="${NAME:-}"
if [[ -z "$name" ]]; then
  echo "env-new: NAME is required, e.g. make env/new NAME=staging" >&2
  exit 1
fi
if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
  echo "env-new: NAME must be lowercase letters, digits and hyphens, got: $name" >&2
  exit 1
fi

values=cluster-configs/overrides/values-$name.yaml
bootstrap=cluster-configs/app-of-apps/app-of-apps-$name.yaml

if [[ "${FORCE:-}" != 1 ]]; then
  for file in "$values" "$bootstrap"; do
    if [[ -e "$file" ]]; then
      echo "env-new: $file already exists; run with FORCE=1 to overwrite" >&2
      exit 1
    fi
  done
fi

cat >"$values" <<YAML
# Values for the $name environment. The app-of-apps chart reads this file; each child Application gets
# \`global\` merged with \`applications.<app>.values\`, on top of the node's own values.yaml.
#
# Merge rules: maps deep-merge, \`null\` deletes a key, and lists replace whole.
# Every key a node accepts is documented in helm-templates/common/README.md.
#
# Every application starts from its node defaults. Add only what differs for this environment.
environment: $name

# The repository and revision Argo CD deploys from. They must match the bootstrap Application in
# cluster-configs/app-of-apps/app-of-apps-$name.yaml (make check/structure enforces it).
repoURL: https://github.com/benhastings/clickhouse-observability-stack.git
targetRevision: main

# The cluster the child Applications deploy into.
destinationServer: https://kubernetes.default.svc

# Applied to every application's values. Uncomment and edit as needed.
# global:
#   labels:
#     environment: $name

# Change one app by writing only the keys you want under applications.<app>.values, for example:
# applications:
#   cerberus:
#     values:
#       deployment:
#         containers:
#           cerberus:
#             resources:
#               limits:
#                 memory: 2Gi
#   demo-load:
#     enabled: false
YAML

cat >"$bootstrap" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps-$name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: observability-$name
  source:
    repoURL: https://github.com/benhastings/clickhouse-observability-stack.git
    targetRevision: main
    path: cluster-configs/app-of-apps
    helm:
      valueFiles:
        - ../overrides/values-$name.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

echo "env-new: wrote $values and $bootstrap"
