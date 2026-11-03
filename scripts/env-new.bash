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
# Values for the $name environment. The defaults are production's: helm-templates/common/values.yaml, then each
# cluster-nodes/<app>/values.yaml. This file holds only what differs for $name; with nothing below, $name
# deploys exactly as prod does. Each child Application gets \`global\` merged with \`applications.<app>.values\`.
#
# Merge rules: maps deep-merge, \`null\` deletes a key, and lists replace whole.
# Every key a node accepts is documented in helm-templates/common/README.md.
environment: $name

# The repository and revision Argo CD deploys from. They must match the bootstrap Application in
# cluster-configs/app-of-apps/app-of-apps-$name.yaml (make check/structure enforces it).
repoURL: https://github.com/benhastings/clickhouse-observability-stack.git
targetRevision: main

# For a tenant namespace that may not create cluster-scoped objects or manage Namespace metadata, start from
# values-restricted.yaml instead (README: A restricted namespace); it sets clusterScoped: false.

# What most sites change first. Uncomment and edit as needed.
# global:
#   # Grafana and OTLP over HTTPS on these hosts, with the TLS Secret named here.
#   exposure:
#     hosts:
#       grafana: grafana.<your-domain>
#       otlp: otlp.<your-domain>
#     tls:
#       credentialName: observability-tls
#   # Every container's default requests and limits; apps that need more set their own.
#   resources:
#     requests:
#       cpu: 10m
#       memory: 32Mi
#     limits:
#       memory: 128Mi
#   # When a platform team already runs the ClickHouse operator, use theirs and install no CRD, ClusterRole
#   # or ClusterRoleBinding for it (README: A shared ClickHouse operator).
#   clickhouseOperator:
#     shared: true

# Change one app by writing only the keys you want under applications.<app>.values, for example:
# applications:
#   grafana:
#     values:
#       auth:
#         genericOauth:
#           authUrl: https://sso.<your-domain>/realms/<realm>/protocol/openid-connect/auth
#           tokenUrl: https://sso.<your-domain>/realms/<realm>/protocol/openid-connect/token
#           apiUrl: https://sso.<your-domain>/realms/<realm>/protocol/openid-connect/userinfo
#   clickhouse:
#     values:
#       clickhouse:
#         storage: 500Gi
#   demo-load:
#     enabled: true
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
