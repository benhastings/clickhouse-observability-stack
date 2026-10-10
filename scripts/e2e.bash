#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_TIMEOUT=${SYNC_TIMEOUT:-1200}
DATA_TIMEOUT=${DATA_TIMEOUT:-300}

step() { echo "==> $*"; }

# On a cluster Argo CD deploys, wait for every Application. Without Argo CD (make helm/install, make dev/up),
# wait for the workloads themselves: every Deployment rolled out and the ClickHouse installation Completed.
if kubectl get crd applications.argoproj.io >/dev/null 2>&1 && kubectl get namespace argocd >/dev/null 2>&1; then
  expected="$(helm template app-of-apps cluster-configs/app-of-apps -f cluster-configs/overrides/values-local.yaml |
    yq ea '[select(.kind == "Application")] | length')"
  expected=$((expected + 1))

  step "Waiting for $expected Applications to be Synced and Healthy"
  deadline=$((SECONDS + SYNC_TIMEOUT))
  while :; do
    status="$(kubectl -n argocd get applications -o json)"
    ready="$(jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length' <<<"$status")"
    total="$(jq '.items | length' <<<"$status")"
    if ((total == expected && ready == expected)); then
      break
    fi
    if ((SECONDS > deadline)); then
      kubectl -n argocd get applications
      jq -r '.items[] | "\(.metadata.name): \(.status.sync.status)/\(.status.health.status) \(.status.conditions // [] | map(.message) | join("; "))"' <<<"$status"
      kubectl get pods -A
      echo "Applications did not become Synced and Healthy within ${SYNC_TIMEOUT}s"
      exit 1
    fi
    echo "  $ready/$expected ready ($total present)"
    sleep 15
  done
else
  step "No Argo CD here: waiting for the workloads"
  deadline=$((SECONDS + SYNC_TIMEOUT))
  until [[ "$(kubectl -n observability get chi otel -o jsonpath='{.status.status}' 2>/dev/null)" == Completed ]]; do
    if ((SECONDS > deadline)); then
      kubectl get pods -A
      echo "the ClickHouse installation did not complete within ${SYNC_TIMEOUT}s"
      exit 1
    fi
    sleep 15
  done
  kubectl -n observability wait job -l app.kubernetes.io/name=clickhouse-schema --for=condition=complete \
    --timeout="${SYNC_TIMEOUT}s"
  for ns in clickhouse-operator observability; do
    for deploy in $(kubectl -n "$ns" get deployments -o name); do
      kubectl -n "$ns" rollout status "$deploy" --timeout="${SYNC_TIMEOUT}s"
    done
  done
fi

kubectl -n observability port-forward svc/cerberus 18081:8080 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/grafana 13000:80 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/otel-collector 14318:4318 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/alertmanager 19093:9093 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 3

cerberus=http://localhost:18081
grafana=http://localhost:13000
otlp=http://localhost:14318
alertmanager=http://localhost:19093
grafana_login="$(kubectl -n observability get secret grafana-admin \
  -o go-template='{{index .data "admin-user" | base64decode}}:{{index .data "admin-password" | base64decode}}')"

poll() {
  local description=$1 check=$2
  shift 2
  local deadline=$((SECONDS + DATA_TIMEOUT)) body
  step "$description"
  while :; do
    body="$(curl -fsS -G "$@" 2>/dev/null || true)"
    if [[ -n "$body" ]] && jq -e "$check" <<<"$body" >/dev/null 2>&1; then
      echo "  ok"
      return 0
    fi
    if ((SECONDS > deadline)); then
      echo "  last response: ${body:0:500}"
      echo "  not satisfied within ${DATA_TIMEOUT}s: $check"
      exit 1
    fi
    sleep 10
  done
}

now="$(date +%s)"
start=$((now - 900))
end=$((now + 900))

poll "PromQL: span metrics exist for checkout and payments" \
  '[.data.result[].metric.service_name] | contains(["checkout", "payments"])' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum by (service_name) (rate(traces_span_metrics_calls[2m]))'

poll "PromQL: payments error ratio is about 25%" \
  '.data.result[0].value[1] | tonumber | . > 0.1 and . < 0.4' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(rate(traces_span_metrics_calls{service_name="payments",span_kind="SPAN_KIND_SERVER",status_code="STATUS_CODE_ERROR"}[2m])) / sum(rate(traces_span_metrics_calls{service_name="payments",span_kind="SPAN_KIND_SERVER"}[2m]))'

poll "PromQL: checkout serves every request without error" \
  '.data.result | length == 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(rate(traces_span_metrics_calls{service_name="checkout",span_kind="SPAN_KIND_SERVER",status_code="STATUS_CODE_ERROR"}[2m])) > 0'

poll "PromQL: service graph metrics exist" \
  '.data.result | length > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=traces_service_graph_request_total'

poll "PromQL: node CPU usage from kubeletstats" \
  '.data.result[0].value[1] | tonumber | . > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(k8s_node_cpu_usage)'

poll "PromQL: node memory working set from kubeletstats" \
  '.data.result[0].value[1] | tonumber | . > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(k8s_node_memory_working_set)'

poll "PromQL: per-pod memory for more than five pods" \
  '.data.result[0].value[1] | tonumber | . > 5' \
  "$cerberus/api/v1/query" --data-urlencode 'query=count(k8s_pod_memory_working_set)'

poll "LogQL: checkout logs arrive" \
  '[.data.result[].values[]] | length > 0' \
  "$cerberus/loki/api/v1/query_range" --data-urlencode 'query={service_name="checkout"}' \
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=10'

poll "TraceQL: failing payments traces are searchable" \
  '.traces | length > 0' \
  "$cerberus/api/search" --data-urlencode 'q={resource.service.name="payments" && status=error}' \
  --data-urlencode "start=$start" --data-urlencode "end=$end" --data-urlencode 'limit=5'

# Correlation, both ways. Grafana asks Loki for categorized labels, which is how the trace_id
# log attribute reaches its derived field; ask the same way here.
step "Log to trace: a checkout log's trace_id opens a trace spanning checkout and payments"
trace_id="$(curl -fsS -G -H 'X-Loki-Response-Encoding-Flags: categorize-labels' "$cerberus/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="checkout"} | main="true"' \
  --data-urlencode "start=$(((now - 300) * 1000000000))" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=1' |
  jq -r '[.data.result[].values[][2].structuredMetadata.trace_id] | first // empty')"
[[ -n "$trace_id" ]] || { echo "  no trace_id on recent checkout logs"; exit 1; }
echo "  trace_id=$trace_id"
poll "  trace $trace_id has spans from both services" \
  '[.. | strings] | contains(["checkout", "payments"])' \
  "$cerberus/api/traces/$trace_id"

step "Trace to logs: a failing payments trace has its error log"
trace_id="$(curl -fsS -G "$cerberus/api/search" --data-urlencode 'q={resource.service.name="payments" && status=error}' \
  --data-urlencode "start=$((now - 300))" --data-urlencode "end=$end" --data-urlencode 'limit=1' |
  jq -r '.traces[0].traceID // empty | (32 - length) as $n | (if $n > 0 then "0" * $n else "" end) + .')"
[[ -n "$trace_id" ]] || { echo "  no failing payments trace found"; exit 1; }
echo "  trace_id=$trace_id"
poll "  payments logs for trace $trace_id include the gateway timeout" \
  '[.data.result[].values[][1]] | index("payment gateway timed out") != null' \
  "$cerberus/loki/api/v1/query_range" --data-urlencode "query={service_name=\"payments\"} | trace_id=\"$trace_id\"" \
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=20'

# A trace that crosses the cluster boundary: the root span comes from outside the cluster, through
# the port-forward, and its child from a pod inside it. Both must land in one trace, parent intact.
step "OTLP from outside the cluster: a host span and an in-cluster child share one trace"
otlp_span() { # service span_id parent_span_id name
  local t1
  t1="$(date +%s%N)"
  jq -nc --arg trace "$cross_trace" --arg svc "$1" --arg span "$2" --arg parent "$3" --arg name "$4" \
    --arg t0 "$((t1 - 20000000))" --arg t1 "$t1" \
    '{resourceSpans: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
      scopeSpans: [{spans: [{traceId: $trace, spanId: $span, parentSpanId: $parent, name: $name,
        kind: 2, startTimeUnixNano: $t0, endTimeUnixNano: $t1}]}]}]}'
}
cross_trace="$(openssl rand -hex 16)"
external_span="$(openssl rand -hex 8)"
internal_span="$(openssl rand -hex 8)"
echo "  trace_id=$cross_trace"
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(otlp_span e2e-external "$external_span" "" "GET /external")" "$otlp/v1/traces"
sender="e2e-otlp-$internal_span"
kubectl -n observability run "$sender" --restart=Never --quiet >/dev/null \
  --image=curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777 -- \
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(otlp_span e2e-internal "$internal_span" "$external_span" "GET /internal")" \
  http://otel-collector:4318/v1/traces
if ! kubectl -n observability wait "pod/$sender" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null; then
  kubectl -n observability logs "$sender" || true
  echo "  the in-cluster span was not sent"
  exit 1
fi
kubectl -n observability delete pod "$sender" --wait=false >/dev/null
poll "  trace $cross_trace has the external root and its in-cluster child" \
  "[.batches[] | {svc: .resource.attributes[\"service.name\"], span: .spans[]}] |
    any(.svc == \"e2e-external\" and .span.spanId == \"$external_span\") and
    any(.svc == \"e2e-internal\" and .span.parentSpanId == \"$external_span\")" \
  "$cerberus/api/traces/$cross_trace"

for uid in cerberus-prometheus cerberus-loki cerberus-tempo; do
  poll "Grafana: datasource $uid is healthy" \
    '.status == "OK"' \
    -u "$grafana_login" "$grafana/api/datasources/uid/$uid/health"
done

poll "Grafana: the span-metrics dashboard is provisioned" \
  '.dashboard.uid == "span-metrics-red"' \
  -u "$grafana_login" "$grafana/api/dashboards/uid/span-metrics-red"

# Each ClickHouse user can do its own job and nothing else: the collector's user inserts but cannot read,
# Cerberus's reads but cannot write or change a table. The data checks above prove the allowed half.
clickhouse_pod="$(kubectl -n observability get pods -l clickhouse.altinity.com/chi=otel -o name | head -1)"
clickhouse_as() { # <admin|writer|reader> <query>
  local password
  password="$(kubectl -n observability get secret "clickhouse-$1" -o go-template='{{.data.password | base64decode}}')"
  kubectl -n observability exec -i "$clickhouse_pod" -c clickhouse -- \
    clickhouse-client --user "otel_$1" --password "$password" --multiquery --query "$2"
}
refused() { # <user> <query>
  local out
  if out="$(clickhouse_as "$1" "$2" 2>&1)"; then
    echo "  otel_$1 was allowed: $2"
    exit 1
  fi
  [[ "$out" == *ACCESS_DENIED* || "$out" == *"Not enough privileges"* ]] ||
    { echo "  otel_$1 failed for another reason: $out"; exit 1; }
  echo "  otel_$1 refused: $2"
}
step "ClickHouse: each user is limited to its own job"
refused writer "SELECT count() FROM otel.otel_traces"
refused writer "ALTER TABLE otel.otel_logs DROP COLUMN EventName"
refused reader "INSERT INTO otel.otel_logs (Body) VALUES ('e2e')"
refused reader "TRUNCATE TABLE otel.otel_logs"
refused reader "CREATE TABLE otel.e2e (a UInt8) ENGINE = Memory"

# The schema is files/schema.sql.tpl in the clickhouse node, not Cerberus's. Ask the Cerberus image this
# stack runs which schema it expects, create that in a scratch database, and compare the two table by table.
# TTLs come from clickhouse.schema.ttlDays and the view's definer from the schema file, so both are ignored.
step "ClickHouse: the otel schema is the one Cerberus expects"
cerberus_image="$(yq '.deployment.containers.cerberus.image | .repository + ":" + .tag' cluster-nodes/cerberus/values.yaml)"
expected_schema="$(docker run --rm -e CERBERUS_CH_DATABASE=otel_expected -e CERBERUS_CH_OPTIMIZATIONS=auto \
  -e CERBERUS_AUTO_CREATE_SCHEMA=true "$cerberus_image" migrate schema)"
clickhouse_as admin "DROP DATABASE IF EXISTS otel_expected; $expected_schema" >/dev/null
schema_of() { # <database>
  clickhouse_as admin "SELECT name, replaceRegexpAll(replaceRegexpAll(replaceAll(create_table_query, '$1.', 'DB.'),
    ' TTL .* SETTINGS', ' SETTINGS'), ' DEFINER = [^ ]+ SQL SECURITY DEFINER', '')
    FROM system.tables WHERE database = '$1' ORDER BY name FORMAT TSVRaw"
}
if ! diff <(schema_of otel) <(schema_of otel_expected); then
  echo "  the otel schema differs from what $cerberus_image expects (< deployed, > expected)"
  exit 1
fi
clickhouse_as admin "DROP DATABASE otel_expected"
echo "  $(schema_of otel | wc -l) tables and views match $cerberus_image"

# Every rule evaluator sends to Alertmanager's v2 API. Post an alert the way one would, and read it back.
step "Alertmanager: an alert posted to the v2 API is grouped and listed"
e2e_alert="e2e-$(openssl rand -hex 4)"
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "[{\"labels\": {\"alertname\": \"$e2e_alert\", \"severity\": \"none\"},
       \"annotations\": {\"summary\": \"posted by scripts/e2e.bash\"}}]" \
  "$alertmanager/api/v2/alerts"
poll "Alertmanager: $e2e_alert is active and routed to the default receiver" \
  "[.[] | select(.labels.alertname == \"$e2e_alert\" and .status.state == \"active\")
   | .receivers[].name] | index(\"default\") != null" \
  "$alertmanager/api/v2/alerts"

# MESH=istio (make test/e2e MESH=istio): the stack runs in Istio and Grafana and OTLP are exposed through
# the ingress gateway on sslip.io hosts. Check the sidecars, both routes, then the same with STRICT mTLS.
if [[ "${MESH:-kubernetes}" == istio ]]; then
  step "Istio: Grafana, Cerberus, the collector and Alertmanager run with a sidecar"
  for app in grafana cerberus otel-collector alertmanager; do
    containers="$(kubectl -n observability get pods -l "app.kubernetes.io/name=$app" \
      -o jsonpath='{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}')"
    [[ " $containers " == *" istio-proxy "* ]] || { echo "  $app has no istio-proxy: $containers"; exit 1; }
    echo "  $app: istio-proxy"
  done

  kubectl -n istio-ingress port-forward svc/istio-ingressgateway 18088:80 >/dev/null 2>&1 &
  sleep 3
  gateway=http://localhost:18088

  mesh_routes() { # <label>
    poll "Istio ($1): Grafana answers through the gateway" \
      '.database == "ok"' \
      -H 'Host: grafana.127.0.0.1.sslip.io' "$gateway/api/health"
    local trace span
    trace="$(openssl rand -hex 16)"
    span="$(openssl rand -hex 8)"
    cross_trace="$trace"
    curl -fsS -o /dev/null -X POST -H 'Host: otlp.127.0.0.1.sslip.io' -H 'Content-Type: application/json' \
      -d "$(otlp_span e2e-gateway "$span" "" "POST through the gateway")" "$gateway/v1/traces"
    poll "Istio ($1): a span sent through the gateway is queryable" \
      "[.batches[].resource.attributes[\"service.name\"]] | index(\"e2e-gateway\") != null" \
      "$cerberus/api/traces/$trace"
  }
  mesh_routes "permissive mTLS"

  step "Istio: require mTLS in observability (PeerAuthentication STRICT)"
  kubectl apply -f - <<'PA'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: observability
spec:
  mtls:
    mode: STRICT
PA
  sleep 20
  mesh_routes "STRICT mTLS"
  now="$(date +%s)"
  poll "Istio (STRICT mTLS): span metrics still arrive from the demo load" \
    '.data.result | length > 0' \
    "$cerberus/api/v1/query" --data-urlencode 'query=sum by (service_name) (rate(traces_span_metrics_calls[1m]))'
fi

echo "e2e: ok"
