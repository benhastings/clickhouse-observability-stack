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
kubectl -n observability port-forward svc/vmalert 18880:8880 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 3

cerberus=http://localhost:18081
grafana=http://localhost:13000
otlp=http://localhost:14318
alertmanager=http://localhost:19093
vmalert=http://localhost:18880
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

# Checkout accepts orders whose payment failed, so only its own database failures (about 2%) are errors.
poll "PromQL: checkout's server error ratio stays under 5%" \
  '.data.result | length == 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=(sum(rate(traces_span_metrics_calls{service_name="checkout",span_kind="SPAN_KIND_SERVER",status_code="STATUS_CODE_ERROR"}[5m])) or vector(0)) / sum(rate(traces_span_metrics_calls{service_name="checkout",span_kind="SPAN_KIND_SERVER"}[5m])) > 0.05'

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

# Cluster state from k8s_cluster, which runs on whichever gateway replica holds the Lease.
step "k8s_cluster: a gateway replica holds the otel-collector-k8s-cluster Lease"
holder="$(kubectl -n observability get lease otel-collector-k8s-cluster -o jsonpath='{.spec.holderIdentity}')"
[[ -n "$holder" ]] || { echo "  the Lease has no holder"; exit 1; }
echo "  held by $holder"
poll "PromQL: the demo-load Deployment has an available replica" \
  '.data.result[0].value[1] | tonumber | . >= 1' \
  "$cerberus/api/v1/query" --data-urlencode 'query=max(k8s_deployment_available{k8s_deployment_name="demo-load"})'
poll "PromQL: container restarts are reported for the demo-load pod" \
  '.data.result | length > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=max by (k8s_pod_name) (k8s_container_restarts{k8s_namespace_name="observability", k8s_pod_name=~"demo-load-.*"})'
poll "PromQL: every node reports Ready" \
  '.data.result[0].value[1] | tonumber | . >= 1' \
  "$cerberus/api/v1/query" --data-urlencode 'query=min(k8s_node_condition_ready)'

poll "LogQL: checkout logs arrive" \
  '[.data.result[].values[]] | length > 0' \
  "$cerberus/loki/api/v1/query_range" --data-urlencode 'query={service_name="checkout"}' \
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=10'

# The collector's k8sattributes adds the owning workload to kubeletstats' pod metrics, matched by their pod UID, so
# a service's pods' resources join to its RED metrics on k8s_deployment_name. (The demo load reports made-up
# Kubernetes attributes for its services, which a sender's own attributes keep, so its spans can't show this.)
poll "PromQL: kubeletstats pod memory carries the deployment that owns the pod" \
  '[.data.result[].metric.k8s_deployment_name] | index("demo-load") != null' \
  "$cerberus/api/v1/query" --data-urlencode 'query=count by (k8s_deployment_name) (k8s_pod_memory_working_set)'

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
otlp_log() { # service body
  jq -nc --arg svc "$1" --arg body "$2" --arg t "$(date +%s%N)" \
    '{resourceLogs: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
      scopeLogs: [{logRecords: [{timeUnixNano: $t, severityText: "INFO", body: {stringValue: $body}}]}]}]}'
}
cross_trace="$(openssl rand -hex 16)"
external_span="$(openssl rand -hex 8)"
internal_span="$(openssl rand -hex 8)"
echo "  trace_id=$cross_trace"
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(otlp_span e2e-external "$external_span" "" "GET /external")" "$otlp/v1/traces"
sender="e2e-otlp-$internal_span"
kubectl -n observability run "$sender" --restart=Never --quiet >/dev/null \
  --image=curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777 --command -- \
  sh -c 'sleep 5; exec curl "$@"' sh -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(otlp_span e2e-internal "$internal_span" "$external_span" "GET /internal")" \
  http://otel-collector:4318/v1/traces \
  --next -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(otlp_log e2e-internal "sent from $sender")" \
  http://otel-collector:4318/v1/logs
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
# The collector's k8sattributes labels what a pod sends with the pod it came from, matched here by the connection's
# source IP. The sender sets no Kubernetes attributes itself, and waits 5 seconds before sending so the processor's
# pod watch has seen its IP. Under Istio the sidecar hides that IP (a sender sets k8s.pod.uid instead), so this
# runs without the mesh.
if [[ "${MESH:-kubernetes}" != istio ]]; then
  poll "  k8sattributes: TraceQL finds the in-cluster span by the pod and namespace that sent it" \
    "[.traces[].traceID | (32 - length) as \$n | (if \$n > 0 then \"0\" * \$n else \"\" end) + .] | index(\"$cross_trace\") != null" \
    "$cerberus/api/search" \
    --data-urlencode "q={resource.k8s.pod.name=\"$sender\" && resource.k8s.namespace.name=\"observability\"}" \
    --data-urlencode "start=$start" --data-urlencode "end=$(date +%s)"
  poll "  k8sattributes: so does its log, as LogQL labels" \
    "[.data.result[].metric | select(.k8s_pod_name == \"$sender\" and .k8s_namespace_name == \"observability\")] | length > 0" \
    "$cerberus/loki/api/v1/query" \
    --data-urlencode 'query=sum by (k8s_pod_name, k8s_namespace_name) (count_over_time({service_name="e2e-internal"} [15m]))'
fi

for uid in cerberus-prometheus cerberus-loki cerberus-tempo; do
  poll "Grafana: datasource $uid is healthy" \
    '.status == "OK"' \
    -u "$grafana_login" "$grafana/api/datasources/uid/$uid/health"
done

poll "Grafana: the span-metrics dashboard is provisioned" \
  '.dashboard.uid == "span-metrics-red"' \
  -u "$grafana_login" "$grafana/api/dashboards/uid/span-metrics-red"
poll "Grafana: the alert hygiene dashboard is provisioned" \
  '.dashboard.uid == "alert-hygiene"' \
  -u "$grafana_login" "$grafana/api/dashboards/uid/alert-hygiene"

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
refused reader "INSERT INTO otel_baseline.baseline (Signal) VALUES ('e2e')"

# The schema is files/schema.sql.tpl in the clickhouse node, not Cerberus's. Ask the Cerberus image this
# stack runs which schema it expects, create that in a scratch database, and compare the two table by table.
# TTLs come from clickhouse.schema.ttlDays and the view's definer from the schema file, so both are ignored.
# The anomaly baselines live in otel_baseline, so they are not part of the comparison.
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

# The clickhouse node's refreshable views keep per-minute signals and hour-of-week baselines in otel_baseline,
# and write each baseline back as gauge series. signal_1m_mv runs every minute on its own; once it has recorded
# a minute of payments traffic, refresh the two hourly views now rather than waiting for the hour, then read a
# baseline through Cerberus. SYSTEM WAIT VIEW fails if the refresh did.
step "ClickHouse: the per-minute signal view records payments"
deadline=$((SECONDS + DATA_TIMEOUT))
until [[ "$(clickhouse_as admin "SELECT count() FROM otel_baseline.signal_1m WHERE ServiceName = 'payments'")" -gt 0 ]]; do
  if ((SECONDS > deadline)); then
    clickhouse_as admin "SELECT view, status, last_success_time, exception FROM system.view_refreshes WHERE database = 'otel_baseline'"
    echo "  otel_baseline.signal_1m has no payments rows after ${DATA_TIMEOUT}s"
    exit 1
  fi
  sleep 10
done
echo "  ok"
step "ClickHouse: the hourly anomaly baseline views refresh without error"
for view in baseline_mv baseline_series_mv; do
  clickhouse_as admin "SYSTEM REFRESH VIEW otel_baseline.$view; SYSTEM WAIT VIEW otel_baseline.$view"
  echo "  otel_baseline.$view refreshed"
done
poll "PromQL: the requests-per-minute baseline exists as a series for payments" \
  '[.data.result[] | select(.metric.service_name == "payments") | .value[1] | tonumber] | length == 1 and .[0] > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=baseline:requests_per_minute:median'

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
# Grafana has no health check for an Alertmanager datasource, so read the alert through it instead.
poll "Grafana: the Alertmanager datasource lists $e2e_alert" \
  "[.[] | .labels.alertname] | index(\"$e2e_alert\") != null" \
  -u "$grafana_login" "$grafana/api/alertmanager/alertmanager/api/v2/alerts"

# Alertmanager's history receiver posts every notification to the collector, which keeps it in otel_logs as a
# log of service alertmanager with the alert's labels as attributes.
history_start=$(($(date +%s) - 300))
poll "LogQL: the history receiver kept $e2e_alert's notification as a log" \
  "[.data.result[] | select(.stream.status == \"firing\") | .values[]] | length > 0" \
  "$cerberus/loki/api/v1/query_range" \
  --data-urlencode "query={service_name=\"alertmanager\"} | alertname=\"$e2e_alert\"" \
  --data-urlencode "start=${history_start}000000000" --data-urlencode "end=$(($(date +%s) + 900))000000000" \
  --data-urlencode 'limit=10'
poll "LogQL: notifications count per alertname, as the alert hygiene dashboard reads them" \
  "[.data.result[].metric.alertname] | index(\"$e2e_alert\") != null" \
  "$cerberus/loki/api/v1/query" \
  --data-urlencode 'query=sum by (alertname) (count_over_time({service_name="alertmanager"} | status="firing" [15m]))'
# Resolve it the way an evaluator would, by posting it again with endsAt. The history log of the resolved
# notification carries how long the alert fired, which the dashboard's time-to-resolve panel reads.
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "[{\"labels\": {\"alertname\": \"$e2e_alert\", \"severity\": \"none\"},
       \"annotations\": {\"summary\": \"posted by scripts/e2e.bash\"},
       \"endsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}]" \
  "$alertmanager/api/v2/alerts"
poll "LogQL: the resolved notification records how long $e2e_alert fired" \
  "[.data.result[] | select(.metric.alertname == \"$e2e_alert\") | .value[1] | tonumber] | length == 1 and .[0] >= 0" \
  "$cerberus/loki/api/v1/query" \
  --data-urlencode 'query=quantile_over_time(0.5, {service_name="alertmanager"} | status="resolved" | unwrap duration_seconds [15m]) by (alertname)'

# vmalert evaluates every rule as ClickHouse SQL through garmr sql-adapter. A rule whose SQL fails is health
# "err" with ClickHouse's message, so every rule evaluated and healthy proves vmalert -> adapter -> ClickHouse.
# The count comes from the rule files, so adding or removing a rule doesn't need an edit here.
rule_count="$(cat cluster-nodes/vmalert/files/rules/*.yaml | grep -cE '^[[:space:]]*- alert:')"
poll "vmalert: all $rule_count rules evaluate through garmr sql-adapter without error" \
  "[.data.groups[].rules[]] | length == $rule_count and all(.health == \"ok\" and .lastEvaluation != \"0001-01-01T00:00:00Z\")" \
  "$vmalert/api/v1/rules"
# The alerting pipeline watches itself: Watchdog always fires and goes to the heartbeat receiver, and
# Alertmanager's notification counters, scraped by the collector, feed AlertmanagerNotificationsFailing.
poll "Alertmanager: vmalert's Watchdog is active and routed to the heartbeat receiver" \
  '[.[] | select(.labels.alertname == "Watchdog" and .status.state == "active") | .receivers[].name]
   | index("heartbeat") != null' \
  "$alertmanager/api/v2/alerts"
poll "PromQL: the collector scrapes Alertmanager's notification counters" \
  '[.data.result[].metric.integration] | index("webhook") != null' \
  "$cerberus/api/v1/query" --data-urlencode 'query=alertmanager_notifications_total'
poll "vmalert: AlertmanagerNotificationsFailing evaluates without error and is not firing" \
  '[.data.groups[].rules[] | select(.name == "AlertmanagerNotificationsFailing" and .health == "ok" and
    .lastEvaluation != "0001-01-01T00:00:00Z" and (.alerts | length) == 0)] | length == 1' \
  "$vmalert/api/v1/rules"
poll "vmalert: BaselineRefreshFailing reads system.view_refreshes as otel_reader without error" \
  '[.data.groups[].rules[] | select(.name == "BaselineRefreshFailing" and .health == "ok" and
    .lastEvaluation != "0001-01-01T00:00:00Z")] | length == 1' \
  "$vmalert/api/v1/rules"
# local turns on Grafana's starter rules, which send to the same Alertmanager through the stack-alertmanager
# contact point. Grafana labels what it sends with the rule's folder.
poll "Alertmanager: Grafana's span error ratio rule fires for payments" \
  '[.[] | select(.labels.grafana_folder == "Observability stack" and .status.state == "active")
   | .labels.service_name] | index("payments") != null' \
  "$alertmanager/api/v2/alerts"
# The demo load's first incident: from 15 minutes after it starts, payments fails 90% of charges instead of 25%,
# for 10 minutes. Until then nothing anomalous may fire. During it ErrorRatioAnomaly must fire for payments,
# print the observed ratio and its baseline, and agree with the PromQL reference rule; after it, resolve.
anomalies='["RequestRateAnomaly", "ErrorRatioAnomaly", "LatencyAnomaly", "ErrorLogAnomaly", "TelemetryAbsent"]'
step "demo load: waiting for the injected incident, 15 minutes after the demo load started"
deadline=$((SECONDS + 1500))
until kubectl -n observability logs deploy/demo-load 2>/dev/null | grep -q "errors incident started"; do
  if ((SECONDS > deadline)); then
    kubectl -n observability logs deploy/demo-load | tail -5
    echo "  the incident did not start within 25 minutes"
    exit 1
  fi
  sleep 15
done
incident_at="$(kubectl -n observability logs --timestamps deploy/demo-load |
  awk '/errors incident started/ && !at { at = $1 } END { print at }')"
incident_start="$(jq -rn --arg t "$incident_at" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601')"
echo "  ok, at $incident_at"
step "Alertmanager: the steady load raised no anomaly alert before the incident"
if curl -fsS "$alertmanager/api/v2/alerts" |
  jq -e --argjson a "$anomalies" '[.[] | .labels.alertname as $n | select($a | index($n))] | length > 0' >/dev/null; then
  curl -fsS "$alertmanager/api/v2/alerts" | jq -c --argjson a "$anomalies" '.[] | .labels as $l | select($a | index($l.alertname)) | $l'
  echo "  an anomaly alert fired on the steady load"
  exit 1
fi
echo "  ok"
DATA_TIMEOUT=900 poll "Alertmanager: vmalert's ErrorRatioAnomaly fires for payments during the incident" \
  '[.[] | select(.labels.alertname == "ErrorRatioAnomaly" and .status.state == "active") | .labels.service_name]
   | index("payments") != null' \
  "$alertmanager/api/v2/alerts"
poll "Alertmanager: ErrorRatioAnomaly prints the observed error ratio and its baseline" \
  '[.[] | select(.labels.alertname == "ErrorRatioAnomaly" and .labels.service_name == "payments")
   | .annotations.description | test("payments errors on [0-9.]+% of server spans; normally [0-9.]+%")] | any' \
  "$alertmanager/api/v2/alerts"
# The reference compares the last 5 minutes with the mean and standard deviation of the hour before them, so it
# is evaluated 5 minutes into the incident: the 5 minutes are all incident and the hour before is all steady
# load. Later, incident minutes enter that hour and drag the mean and deviation up until it stops firing,
# which is the weakness the median and MAD in the ClickHouse rule avoid.
reference="$(yq '.groups[] | select(.name == "anomaly-reference-recent") | .rules[] | select(.alert == "ErrorRatioAnomaly") | .expr' \
  cluster-nodes/vmalert/files/reference/anomaly.yaml)"
poll "PromQL: the reference ErrorRatioAnomaly agrees 5 minutes into the incident, through Cerberus" \
  '[.data.result[].metric.service_name] | index("payments") != null' \
  "$cerberus/api/v1/query" --data-urlencode "query=$reference" --data-urlencode "time=$((incident_start + 300))"
DATA_TIMEOUT=1200 poll "Alertmanager: ErrorRatioAnomaly resolves for payments after the incident" \
  '[.[] | select(.labels.alertname == "ErrorRatioAnomaly" and .labels.service_name == "payments"
   and .status.state == "active")] | length == 0' \
  "$alertmanager/api/v2/alerts"
poll "LogQL: the alert history kept ErrorRatioAnomaly's resolution" \
  '[.data.result[].values[]] | length > 0' \
  "$cerberus/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="alertmanager"} | alertname="ErrorRatioAnomaly" | status="resolved"' \
  --data-urlencode "start=$(($(date +%s) - 3600))000000000" --data-urlencode "end=$(($(date +%s) + 60))000000000" \
  --data-urlencode 'limit=10'

# MESH=istio (make test/e2e MESH=istio): the stack runs in Istio and Grafana and OTLP are exposed through
# the ingress gateway on sslip.io hosts. Check the sidecars, both routes, then the same with STRICT mTLS.
if [[ "${MESH:-kubernetes}" == istio ]]; then
  step "Istio: Grafana, Cerberus, the collector, Alertmanager, vmalert and garmr sql-adapter run with a sidecar"
  for app in grafana cerberus otel-collector alertmanager vmalert garmr-sql-adapter; do
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
