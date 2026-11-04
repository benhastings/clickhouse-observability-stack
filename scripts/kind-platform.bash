#!/usr/bin/env bash
# cspell:words newkey keyout addext CAcreateserial extfile
# kind-platform.bash <env>: on kind, do what a platform team does before a restricted tenant's first sync (README:
# A restricted namespace, A standalone ClickHouse), for make test/e2e ENV=restricted and ENV=standalone:
#   1. the stack's namespace, labelled istio-injection: enabled
#   2. for a ClickHouse the operator runs (restricted): the Altinity operator in its own namespace, outside the
#      mesh, with its CRDs and cluster RBAC, from this repository's clickhouse-operator node: the shared operator
#      global.clickhouseOperator.shared expects
#      for a standalone ClickHouse (global.clickhouse.standalone): no operator, but the server's certificate. A
#      throwaway CA and a certificate for global.clickhouse.tls.serverName, generated here with openssl and never
#      written outside a temporary directory, become the kubernetes.io/tls Secret tls.serverSecret and the CA
#      ConfigMap tls.caConfigMap. The CA's key is deleted on exit, so nothing can issue another certificate.
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

if [[ "$(yq '.global.clickhouse.standalone // false' "$values")" == true ]]; then
  server_name="$(yq '.global.clickhouse.tls.serverName' "$values")"
  server_secret="$(yq '.global.clickhouse.tls.serverSecret' "$values")"
  ca_configmap="$(yq '.global.clickhouse.tls.caConfigMap' "$values")"
  ca_key="$(yq '.global.clickhouse.tls.caKey // "ca.crt"' "$values")"
  echo "==> Platform: a throwaway CA, and a certificate for $server_name in Secret $server_secret"
  pki="$(mktemp -d)"
  trap 'rm -rf "$pki"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=kind platform CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$pki/ca.key" -out "$pki/ca.crt" 2>/dev/null
  # Only the name the clients verify: a client dialling the Service by any other name has to be refused.
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$server_name" -keyout "$pki/tls.key" -out "$pki/tls.csr" 2>/dev/null
  openssl x509 -req -in "$pki/tls.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial -days 2 \
    -extfile <(printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n' "$server_name") \
    -out "$pki/tls.crt" 2>/dev/null
  # The certificate and key are a kubernetes.io/tls Secret; the CA bundle is public, so a ConfigMap. A re-run on
  # the same cluster keeps the first pair.
  if ! kubectl -n "$stack_ns" get secret "$server_secret" >/dev/null 2>&1; then
    kubectl -n "$stack_ns" create secret tls "$server_secret" --cert="$pki/tls.crt" --key="$pki/tls.key" >/dev/null
    kubectl -n "$stack_ns" create configmap "$ca_configmap" --from-file="$ca_key=$pki/ca.crt" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "    created $stack_ns/$server_secret and $stack_ns/$ca_configmap"
  fi
else
  echo "==> Platform: the shared ClickHouse operator in $operator_ns"
  helm upgrade --install clickhouse-operator cluster-nodes/clickhouse-operator --namespace "$operator_ns" \
    --create-namespace --set global.mesh=kubernetes --wait --timeout 5m
  kubectl wait --for=condition=Established crd/clickhouseinstallations.clickhouse.altinity.com --timeout=120s
fi

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
