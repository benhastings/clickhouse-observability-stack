# shellcheck shell=bash disable=SC2154
# cspell:words newkey keyout
# Sourced by scripts/e2e-restricted.bash for ENV=standalone, once the probe's trace, log and metric have been written
# and read back: ClickHouse serves only TLS, and its clients verify it.
#   - nothing listens on a plaintext port: native 9000, HTTP 8123, MySQL 9004, PostgreSQL 9005, interserver 9009
#   - every native query in system.query_log arrived over TLS, with queries from the collector's, the readers' and
#     the schema Job's users
#   - with the schema Job's own client config, the server is accepted by the platform's CA and its name, and refused
#     with another CA, by any other name, and without TLS
# It uses e2e-restricted.bash's $ns and $restricted_values, and e2e.bash's step.

server_name="$(yq '.global.clickhouse.tls.serverName' "$restricted_values")"
ca_configmap="$(yq '.global.clickhouse.tls.caConfigMap' "$restricted_values")"
ca_key="$(yq '.global.clickhouse.tls.caKey // "ca.crt"' "$restricted_values")"
tls_port="$(yq '.global.services.clickhouse' "$restricted_values")"
tls_port="${tls_port##*:}"

step "ClickHouse: listens on $tls_port and 8443, and on no plaintext client port"
# The pod's sockets in LISTEN state (st 0A), from the kernel's table: the server image has no ss or netstat.
listening=" "
while read -r hex; do
  listening+="$((16#$hex)) "
done < <(kubectl -n "$ns" exec deploy/clickhouse -c clickhouse -- cat /proc/net/tcp /proc/net/tcp6 |
  awk '$4 == "0A" { n = split($2, a, ":"); print a[n] }' | sort -u)
for port in "$tls_port" 8443; do
  [[ "$listening" == *" $port "* ]] || { echo "  nothing listens on $port; listening:$listening"; exit 1; }
done
for port in 9000 8123 9004 9005 9009; do
  [[ "$listening" != *" $port "* ]] || { echo "  ClickHouse listens on plaintext port $port; listening:$listening"; exit 1; }
done
echo "  ok: listening on$listening"

# A client pod with the server's image, for its clickhouse-client, and the platform's CA bundle mounted where the
# schema Job mounts it.
image="$(kubectl -n "$ns" get deployment clickhouse -o jsonpath='{.spec.template.spec.containers[?(@.name=="clickhouse")].image}')"
tls_client="e2e-tls-$(openssl rand -hex 4)"
step "ClickHouse: a client pod $tls_client with the schema Job's client config"
kubectl apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata:
  name: $tls_client
  namespace: $ns
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: $image
      command: [sleep, "1800"]
      env:
        - name: HOME
          value: /tmp
      resources:
        requests:
          cpu: 10m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 256Mi
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: clickhouse-ca
          mountPath: /etc/clickhouse-ca
          readOnly: true
  volumes:
    - name: clickhouse-ca
      configMap:
        name: $ca_configmap
POD
kubectl -n "$ns" wait "pod/$tls_client" --for=condition=Ready --timeout=180s >/dev/null

# The client config the schema Job writes, read from the live Job, so this tests what is deployed.
job_script="$(kubectl -n "$ns" get jobs -l app.kubernetes.io/name=clickhouse-schema \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].command[2]}')"
job_config="$(sed -n '/^cat >\/tmp\/client.xml <<EOF$/,/^EOF$/{//!p}' <<<"$job_script")"
[[ "$job_config" == *"<verificationMode>strict</verificationMode>"* ]] ||
  { echo "  the schema Job writes no strict client config: ${job_config:0:500}"; exit 1; }
# Another CA, which signed nothing the server has.
untrusted="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=untrusted e2e CA" \
  -keyout "$untrusted/ca.key" -out "$untrusted/ca.crt" 2>/dev/null
kubectl -n "$ns" exec -i "$tls_client" -c client -- sh -c 'cat >/tmp/untrusted-ca.crt' <"$untrusted/ca.crt"
rm -rf "$untrusted"
for ca in trusted untrusted; do
  ca_file="/etc/clickhouse-ca/$ca_key"
  [[ "$ca" == trusted ]] || ca_file=/tmp/untrusted-ca.crt
  # shellcheck disable=SC2016 # the Job's literal $CLICKHOUSE_CA_FILE
  kubectl -n "$ns" exec -i "$tls_client" -c client -- sh -c "cat >/tmp/$ca.xml" <<<"${job_config//'$CLICKHOUSE_CA_FILE'/$ca_file}"
done
echo "  ok"

admin_password="$(kubectl -n "$ns" get secret clickhouse-admin -o go-template='{{.data.password | base64decode}}')"
# tls_client_query <trusted|untrusted|plaintext> <host> <server-name override, or ""> <query>
tls_client_query() {
  local args=(--host "$2" --port "$tls_port" --user otel_admin --password "$admin_password" --query "$4")
  [[ "$1" == plaintext ]] || args+=(--config-file "/tmp/$1.xml" --secure)
  [[ -z "$3" ]] || args+=(--tls-sni-override "$3")
  kubectl -n "$ns" exec "$tls_client" -c client -- clickhouse-client "${args[@]}"
}
# tls_refused <description> <tls_client_query args...>: the connection fails, on the certificate when over TLS.
tls_refused() {
  local description=$1 out
  shift
  if out="$(tls_client_query "$@" 2>&1)"; then
    echo "  accepted $description"
    exit 1
  fi
  if [[ "$1" != plaintext ]] && ! grep -qiE 'certificate|ssl' <<<"$out"; then
    echo "  $description failed, but not on the certificate: ${out:0:500}"
    exit 1
  fi
  echo "  refused $description: $(head -1 <<<"$out" | cut -c1-200)"
}

step "ClickHouse: the schema Job's client accepts the server by $server_name with the platform's CA"
out="$(tls_client_query trusted "$server_name" "$server_name" 'SELECT 1' 2>&1)" ||
  { echo "  ${out:0:500}"; exit 1; }
[[ "$out" == 1 ]] || { echo "  SELECT 1 returned: ${out:0:500}"; exit 1; }
echo "  ok"

step "ClickHouse: a client with another CA, dialling another name, or without TLS is refused"
tls_refused "a CA that did not sign the server's certificate" untrusted "$server_name" "$server_name" 'SELECT 1'
tls_refused "the name $server_name.$ns.svc.cluster.local, which the certificate does not carry" \
  trusted "$server_name.$ns.svc.cluster.local" "" 'SELECT 1'
tls_refused "a plaintext client on $tls_port" plaintext "$server_name" "" 'SELECT 1'

# Native queries (interface 1) say whether they arrived over TLS; Cerberus's arrive over HTTPS on 8443, which the
# listener check above already holds to TLS, since there is no plaintext HTTP port.
step "ClickHouse: every native query in system.query_log arrived over TLS"
tls_client_query trusted "$server_name" "$server_name" 'SYSTEM FLUSH LOGS' >/dev/null
by_user="$(tls_client_query trusted "$server_name" "$server_name" "SELECT user, count() AS queries,
  countIf(interface = 1 AND NOT is_secure) AS plaintext FROM system.query_log WHERE type = 'QueryStart' AND event_time > now() - INTERVAL 2 HOUR
  GROUP BY user ORDER BY user FORMAT JSONEachRow")"
echo "  ${by_user//$'\n'/$'\n'  }"
jq -se 'map(select((.plaintext | tonumber) != 0)) | length == 0' <<<"$by_user" >/dev/null ||
  { echo "  a query arrived without TLS"; exit 1; }
for user in otel_writer otel_reader otel_admin; do
  jq -se --arg user "$user" 'map(select(.user == $user and (.queries | tonumber) > 0)) | length == 1' <<<"$by_user" >/dev/null ||
    { echo "  no query from $user"; exit 1; }
done
echo "  ok"

kubectl -n "$ns" delete pod "$tls_client" --wait=false >/dev/null
