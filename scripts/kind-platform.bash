#!/usr/bin/env bash
# cspell:words newkey keyout addext CAcreateserial extfile
# kind-platform.bash <env>: on kind, do what a platform team does before a restricted tenant's first sync (README:
# A restricted namespace, A standalone ClickHouse), for make test/e2e ENV=restricted, ENV=standalone and
# ENV=tenant-vault:
#   1. the stack's namespace, labelled istio-injection: enabled, or istio.io/dataplane-mode: ambient for an
#      environment in ambient mode (global.istio.dataplaneMode)
#   2. for a ClickHouse the operator runs (restricted): the Altinity operator in its own namespace, outside the
#      mesh, with its CRDs and cluster RBAC, from this repository's clickhouse-operator node: the shared operator
#      global.clickhouseOperator.shared expects
#      for a standalone ClickHouse (global.clickhouse.standalone): no operator, but the server's certificate. A
#      throwaway CA and a certificate for global.clickhouse.tls.serverName, generated here with openssl and never
#      written outside a temporary directory, become the kubernetes.io/tls Secret tls.serverSecret and the CA
#      ConfigMap tls.caConfigMap. The CA's key is deleted on exit, so nothing can issue another certificate.
#      With tls.vault they are fields of the Vault record instead (4).
#   3. the Gateway the environment's global.exposure.gateway names, serving its Grafana host over plain HTTP
#   4. for an environment on Vault (global.vault.enabled): Vault in dev mode and its Agent Injector, in the vault
#      namespace and outside the mesh, at pinned versions; Kubernetes auth, with the role global.vault.role bound to
#      every ServiceAccount in the stack's namespace and allowed to read only the stack's records; and those
#      records, one field per entry scripts/secret-records.bash lists from the environment's golden render: random
#      passwords, otel_<user> and admin as usernames, and the certificate, key and CA from (2). Nothing is written
#      to the repository, and no Kubernetes Secret is created.
# Istio comes first (scripts/kind-istio.bash), and for an environment off Vault the Secrets (scripts/local-secrets.bash).
set -euo pipefail
cd "$(dirname "$0")/.."

VAULT_CHART_VERSION=0.34.1

env=${1:?usage: kind-platform.bash <env>}
values="cluster-configs/overrides/values-$env.yaml"
apps=cluster-configs/app-of-apps/values.yaml
stack_ns="$(yq '.namespace' "$apps")"
operator_ns="$(yq '.global.networkPolicy.namespaces.operator // "clickhouse-operator"' "$values")"
gateway="$(yq '.global.exposure.gateway.name' "$values")"
gateway_ns="$(yq '.global.exposure.gateway.namespace' "$values")"
grafana_host="$(yq '.global.exposure.hosts.grafana' "$values")"

on_vault="$(yq '.global.vault.enabled // false' "$values")"
tls_vault="$(yq '.global.clickhouse.tls.vault // false' "$values")"

kubectl create namespace "$stack_ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [[ "$(yq '.global.istio.dataplaneMode // "sidecar"' "$values")" == ambient ]]; then
  echo "==> Platform: namespace $stack_ns, labelled for Istio's ambient mode"
  kubectl label namespace "$stack_ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
else
  echo "==> Platform: namespace $stack_ns, labelled for Istio injection"
  kubectl label namespace "$stack_ns" istio-injection=enabled --overwrite >/dev/null
fi

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
  # the same cluster keeps the first pair. With tls.vault they go into the Vault record below instead.
  if [[ "$tls_vault" != true ]] && ! kubectl -n "$stack_ns" get secret "$server_secret" >/dev/null 2>&1; then
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

if [[ "$on_vault" == true ]]; then
  role="$(yq '.global.vault.role' "$values")"
  record="$(yq '.global.vault.secret // ""' "$values")"
  echo "==> Platform: Vault $VAULT_CHART_VERSION in dev mode, and its Agent Injector, in namespace vault"
  helm upgrade --install vault vault --repo https://helm.releases.hashicorp.com --version "$VAULT_CHART_VERSION" \
    --namespace vault --create-namespace --wait --timeout 5m \
    --set server.dev.enabled=true --set server.dev.devRootToken=root --set injector.enabled=true
  kubectl -n vault wait pod/vault-0 --for=condition=Ready --timeout=180s >/dev/null
  kubectl -n vault rollout status deployment/vault-agent-injector --timeout=180s >/dev/null
  vault() { kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN=root vault "$@"; }

  # The records and fields the environment's pods read, from its golden render: "<path>, field <field>".
  records="$(scripts/secret-records.bash "tests/golden/$env" | awk '$2 == "vault" { $1 = $2 = ""; print }' |
    sed -E 's/^ +//' | sort -u)"
  [[ -n "$records" ]] || { echo "kind-platform: tests/golden/$env reads nothing from Vault" >&2; exit 1; }

  echo "==> Platform: Kubernetes auth, role $role for every ServiceAccount in $stack_ns"
  vault auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1 || vault auth enable kubernetes >/dev/null
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
  # Read access to exactly the records the render names (KV v2: secret/data/<record>).
  policy="$(cut -d, -f1 <<<"$records" | sort -u | sed -E 's|^(.*)$|path "\1" { capabilities = ["read"] }|')"
  vault policy write "$role" - <<<"$policy" >/dev/null
  vault write "auth/kubernetes/role/$role" bound_service_account_names='*' \
    bound_service_account_namespaces="$stack_ns" policies="$role" ttl=1h >/dev/null

  # value_for <field>: what a platform's Vault would hold for one field of the one record global.vault.secret
  # (<Secret name>-<key>, the shape tenant-vault reads).
  [[ -n "$record" ]] || { echo "kind-platform: $env sets no global.vault.secret; only the one-record shape is supported" >&2; exit 1; }
  server_secret="$(yq '.global.clickhouse.tls.serverSecret // ""' "$values")"
  ca_configmap="$(yq '.global.clickhouse.tls.caConfigMap // ""' "$values")"
  ca_key="$(yq '.global.clickhouse.tls.caKey // "ca.crt"' "$values")"
  random_password() { od -An -N18 -tx1 /dev/urandom | tr -d ' \n'; }
  value_for() {
    case "$1" in
      "$server_secret-tls.crt") cat "$pki/tls.crt" ;;
      "$server_secret-tls.key") cat "$pki/tls.key" ;;
      "$ca_configmap-$ca_key") cat "$pki/ca.crt" ;;
      grafana-admin-admin-user) echo admin ;;
      clickhouse-*-username) local user=${1#clickhouse-}; echo "otel_${user%-username}" ;;
      *-password) random_password ;;
      *) echo "kind-platform: no value for Vault field $1" >&2; return 1 ;;
    esac
  }

  # One kv put per record, with every field it needs. A re-run on the same cluster keeps a record that exists.
  while read -r path; do
    kv_path="${path/\/data\//\/}"
    if vault kv get "$kv_path" >/dev/null 2>&1; then
      echo "    $kv_path exists, kept"
      continue
    fi
    args=()
    while read -r field; do
      args+=("$field=$(value_for "$field")")
    done < <(grep -F "$path, field " <<<"$records" | sed -E 's/^.*, field //')
    vault kv put "$kv_path" "${args[@]}" >/dev/null
    echo "    wrote $kv_path: ${#args[@]} fields"
  done < <(cut -d, -f1 <<<"$records" | sort -u)
fi
