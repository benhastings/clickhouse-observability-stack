#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_TIMEOUT=${SYNC_TIMEOUT:-1200}
DATA_TIMEOUT=${DATA_TIMEOUT:-300}

step() { echo "==> $*"; }

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

kubectl -n observability port-forward svc/cerberus 18081:8080 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/grafana 13000:80 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/otel-collector 14318:4318 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 3

cerberus=http://localhost:18081
grafana=http://localhost:13000
otlp=http://localhost:14318
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

echo "e2e: ok"
