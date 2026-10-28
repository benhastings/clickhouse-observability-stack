# shellcheck shell=bash disable=SC2154
# Sourced by scripts/e2e.bash for ENV=restricted (make test/e2e ENV=restricted): the restricted-namespace profile on
# kind, after scripts/kind-platform.bash has done the platform team's part. No demo load runs, so a pod in the
# namespace sends its own trace, log and metric, and each is read back through Cerberus and through Grafana.
# It uses e2e.bash's step and poll, the port-forwarded $cerberus and $grafana, $grafana_login, $start and $end.

ns="$(yq '.namespace' cluster-configs/app-of-apps/values.yaml)"
restricted_values=cluster-configs/overrides/values-restricted.yaml
operator_ns="$(yq '.global.networkPolicy.namespaces.operator // "clickhouse-operator"' "$restricted_values")"
grafana_host="$(yq '.global.exposure.hosts.grafana' "$restricted_values")"

if kubectl get namespace argocd >/dev/null 2>&1; then
  project="$(yq '.spec.project' cluster-configs/app-of-apps/app-of-apps-restricted.yaml)"
  step "Argo CD: the $project AppProject allows no cluster-scoped kind"
  kubectl -n argocd get appproject "$project" -o json | jq -e '.spec.clusterResourceWhitelist // [] | length == 0' >/dev/null ||
    { echo "  $project allows: $(kubectl -n argocd get appproject "$project" -o jsonpath='{.spec.clusterResourceWhitelist}')"; exit 1; }
  echo "  ok"
  step "Argo CD: every object the Applications manage is in $ns or argocd, and none is cluster-scoped"
  outside="$(kubectl -n argocd get applications -o json | jq -r --arg ns "$ns" '.items[] | .metadata.name as $app |
    .status.resources[]? | select(.namespace != $ns and .namespace != "argocd") | "\($app): \(.kind)/\(.name) in \(.namespace // "the cluster")"')"
  [[ -z "$outside" ]] || { echo "  ${outside//$'\n'/$'\n'  }"; exit 1; }
  echo "  ok"
  step "Argo CD: no Application installs the ClickHouse operator or creates a namespace"
  installs="$(kubectl -n argocd get applications -o json | jq -r '.items[] |
    select((.spec.source.path // "" | endswith("cluster-nodes/clickhouse-operator")) or
      (.spec.syncPolicy.syncOptions // [] | index("CreateNamespace=true")) or .spec.syncPolicy.managedNamespaceMetadata != null) |
    .metadata.name')"
  [[ -z "$installs" ]] || { echo "  $installs"; exit 1; }
  echo "  ok"
fi

step "ClickHouse: the shared operator in $operator_ns reconciled the installation in $ns"
[[ -z "$(kubectl -n "$ns" get deployments -l app.kubernetes.io/name=clickhouse-operator -o name)" ]] ||
  { echo "  $ns runs its own ClickHouse operator"; exit 1; }
kubectl -n "$operator_ns" wait deployment -l app.kubernetes.io/name=clickhouse-operator --for=condition=Available \
  --timeout=60s >/dev/null
chi_status="$(kubectl -n "$ns" get chi otel -o jsonpath='{.status.status}')"
[[ "$chi_status" == Completed ]] || { echo "  the installation is $chi_status, not Completed"; exit 1; }
kubectl -n "$ns" wait pod -l clickhouse.altinity.com/chi=otel --for=condition=Ready --timeout=120s >/dev/null
echo "  ok: Completed, every ClickHouse pod Ready"

step "Collector: runs as a gateway only, with no agent DaemonSet"
kubectl -n "$ns" rollout status deployment/otel-collector --timeout=60s >/dev/null
[[ -z "$(kubectl -n "$ns" get daemonsets -o name)" ]] || { echo "  $ns runs a DaemonSet"; exit 1; }
echo "  ok"

step "Cerberus: ready"
curl -fsS -o /dev/null --retry 10 --retry-all-errors --retry-delay 5 "$cerberus/readyz"
echo "  ok"

# One of each signal, sent from a pod in the namespace (through its sidecar) to the collector's Service.
probe_service=e2e-restricted
probe_run="$(openssl rand -hex 8)"
probe_trace="$(openssl rand -hex 16)"
probe_t1="$(date +%s%N)"
probe_span="$(jq -nc --arg svc "$probe_service" --arg trace "$probe_trace" --arg span "$(openssl rand -hex 8)" \
  --arg t0 "$((probe_t1 - 20000000))" --arg t1 "$probe_t1" \
  '{resourceSpans: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeSpans: [{spans: [{traceId: $trace, spanId: $span, name: "GET /restricted", kind: 2,
      startTimeUnixNano: $t0, endTimeUnixNano: $t1}]}]}]}')"
probe_log="$(jq -nc --arg svc "$probe_service" --arg run "$probe_run" --arg t "$probe_t1" --arg trace "$probe_trace" \
  '{resourceLogs: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeLogs: [{logRecords: [{timeUnixNano: $t, severityText: "INFO", traceId: $trace,
      body: {stringValue: ("restricted probe " + $run)}, attributes: [{key: "run", value: {stringValue: $run}}]}]}]}]}')"
probe_metric="$(jq -nc --arg svc "$probe_service" --arg run "$probe_run" --arg t "$probe_t1" \
  '{resourceMetrics: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeMetrics: [{metrics: [{name: "e2e_restricted_probe", gauge: {dataPoints: [{timeUnixNano: $t, asDouble: 42,
      attributes: [{key: "run", value: {stringValue: $run}}]}]}}]}]}]}')"
step "Collector: a pod in $ns sends a trace, a log and a metric (run $probe_run)"
sender="e2e-restricted-$probe_run"
kubectl -n "$ns" run "$sender" --restart=Never --quiet >/dev/null \
  --image=curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777 --command -- \
  sh -c 'sleep 5; exec curl "$@"' sh \
  -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d "$probe_span" http://otel-collector:4318/v1/traces \
  --next -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d "$probe_log" http://otel-collector:4318/v1/logs \
  --next -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d "$probe_metric" http://otel-collector:4318/v1/metrics
if ! kubectl -n "$ns" wait "pod/$sender" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null; then
  kubectl -n "$ns" logs "$sender" --all-containers || true
  echo "  the probe was not sent"
  exit 1
fi
kubectl -n "$ns" delete pod "$sender" --wait=false >/dev/null
echo "  ok"

trace_check="[.batches[].resource.attributes[\"service.name\"]] | index(\"$probe_service\") != null"
log_check="[.data.result[].values[][1]] | index(\"restricted probe $probe_run\") != null"
metric_check='[.data.result[].value[1] | tonumber] == [42]'
log_query=(--data-urlencode "query={service_name=\"$probe_service\"} | run=\"$probe_run\""
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=10')
metric_query=(--data-urlencode "query=e2e_restricted_probe{service_name=\"$probe_service\", run=\"$probe_run\"}")

poll "TraceQL: Cerberus reads the probe trace $probe_trace" "$trace_check" "$cerberus/api/traces/$probe_trace"
poll "LogQL: Cerberus reads the probe log" "$log_check" "$cerberus/loki/api/v1/query_range" "${log_query[@]}"
poll "PromQL: Cerberus reads the probe metric" "$metric_check" "$cerberus/api/v1/query" "${metric_query[@]}"

# The collector scrapes its own telemetry: what its clickhouse exporter sent, per signal.
for signal in spans log_records metric_points; do
  poll "PromQL: the collector's clickhouse exporter has sent $signal" \
    '[.data.result[] | select(.metric.exporter == "clickhouse" and (.value[1] | tonumber) > 0)] | length > 0' \
    "$cerberus/api/v1/query" --data-urlencode "query=otelcol_exporter_sent_$signal"
done

for uid in cerberus-prometheus cerberus-loki cerberus-tempo; do
  poll "Grafana: datasource $uid is healthy" \
    '.status == "OK"' \
    -u "$grafana_login" "$grafana/api/datasources/uid/$uid/health"
done
poll "Grafana: the Alertmanager datasource answers" \
  'type == "array"' \
  -u "$grafana_login" "$grafana/api/alertmanager/alertmanager/api/v2/alerts"

proxy="$grafana/api/datasources/proxy/uid"
poll "Grafana: the Tempo datasource opens the probe trace" "$trace_check" \
  -u "$grafana_login" "$proxy/cerberus-tempo/api/traces/$probe_trace"
poll "Grafana: the Loki datasource finds the probe log" "$log_check" \
  -u "$grafana_login" "$proxy/cerberus-loki/loki/api/v1/query_range" "${log_query[@]}"
poll "Grafana: the Prometheus datasource reads the probe metric" "$metric_check" \
  -u "$grafana_login" "$proxy/cerberus-prometheus/api/v1/query" "${metric_query[@]}"

# Grafana's VirtualService binds it to the platform's Gateway; reach it the way a browser would, by its host.
kubectl -n istio-ingress port-forward svc/istio-ingressgateway 18088:80 >/dev/null 2>&1 &
sleep 3
poll "Istio: Grafana answers as $grafana_host through the platform's Gateway" \
  '.database == "ok"' \
  -H "Host: $grafana_host" http://localhost:18088/api/health
poll "Istio: the Prometheus datasource is healthy through the Gateway too" \
  '.status == "OK"' \
  -u "$grafana_login" -H "Host: $grafana_host" http://localhost:18088/api/datasources/uid/cerberus-prometheus/health

# Every Secret value the stack reads, looked for in its pods' logs and in the live objects that configure them.
# Only the Secret's name is printed.
step "Credentials: no Secret value appears in $ns's logs, ConfigMaps, workloads or Applications"
haystack="$(mktemp)"
for pod in $(kubectl -n "$ns" get pods -o name); do
  kubectl -n "$ns" logs "$pod" --all-containers >>"$haystack" 2>/dev/null || true
done
kubectl -n "$ns" get configmaps,deployments,jobs,chi -o yaml >>"$haystack"
kubectl -n argocd get applications -o yaml >>"$haystack" 2>/dev/null || true
leaks=()
for ref in clickhouse-admin:password clickhouse-writer:password clickhouse-reader:password \
  clickhouse-analyst:password clickhouse-garmr:password grafana-admin:admin-password; do
  value="$(kubectl -n "$ns" get secret "${ref%%:*}" -o go-template="{{index .data \"${ref#*:}\" | base64decode}}")"
  [[ -n "$value" ]] || { echo "  ${ref%%:*} has no ${ref#*:}"; rm -f "$haystack"; exit 1; }
  grep -qF -f <(printf '%s\n' "$value") "$haystack" && leaks+=("${ref%%:*}")
done
rm -f "$haystack"
((${#leaks[@]} == 0)) || { echo "  found the value of: ${leaks[*]}"; exit 1; }
echo "  ok: $(kubectl -n "$ns" get pods -o name | wc -l) pods' logs and the live objects hold none of 6 Secret values"
