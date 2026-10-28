#!/usr/bin/env bash
# kind-platform.bash <env>: on kind, do what a platform team does before a restricted tenant's first sync (README:
# A restricted namespace), for make test/e2e ENV=restricted:
#   1. the stack's namespace, labelled istio-injection: enabled
#   2. the Altinity operator in its own namespace, outside the mesh, with its CRDs and cluster RBAC, from this
#      repository's clickhouse-operator node: the shared operator global.clickhouseOperator.shared expects
#   3. the Gateway the environment's global.exposure.gateway names, serving its Grafana host over plain HTTP
# Istio comes first (scripts/kind-istio.bash), and the Secrets (scripts/local-secrets.bash).
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: kind-platform.bash <env>}
values="cluster-configs/overrides/values-$env.yaml"
apps=cluster-configs/app-of-apps/values.yaml
stack_ns="$(yq '.namespace' "$apps")"
operator_ns="$(yq '.global.networkPolicy.namespaces.operator // "clickhouse-operator"' "$values")"
gateway="$(yq '.global.exposure.gateway.name' "$values")"
gateway_ns="$(yq '.global.exposure.gateway.namespace' "$values")"
grafana_host="$(yq '.global.exposure.hosts.grafana' "$values")"

echo "==> Platform: namespace $stack_ns, labelled for Istio injection"
kubectl create namespace "$stack_ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$stack_ns" istio-injection=enabled --overwrite >/dev/null

echo "==> Platform: the shared ClickHouse operator in $operator_ns"
helm upgrade --install clickhouse-operator cluster-nodes/clickhouse-operator --namespace "$operator_ns" \
  --create-namespace --set global.mesh=kubernetes --wait --timeout 5m
kubectl wait --for=condition=Established crd/clickhouseinstallations.clickhouse.altinity.com --timeout=120s

echo "==> Platform: Gateway $gateway_ns/$gateway for $grafana_host"
kubectl apply -f - <<GATEWAY
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: $gateway
  namespace: $gateway_ns
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - $grafana_host
GATEWAY
