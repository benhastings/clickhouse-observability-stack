#!/usr/bin/env bash
# cspell:words statefulsets endpointslices replicasets replicaset tostring
# acceptance.bash <env>: the in-environment proof of the release gates (docs/go-no-go.md), against the current kube
# context and the environment's namespace (make test/acceptance ENV=<env>). It creates no cluster, installs
# nothing, creates no object and never reads a Secret's data: apart from one synthetic trace, log and metric sent
# to the collector, it only reads. Each check prints PASS, FAIL or SKIP, and it exits 1 when any check fails:
#   - every Argo CD Application of the environment is Synced and Healthy (when this context can read them), and
#     every Deployment and StatefulSet in the namespace is ready and no Job in it has failed
#   - ClickHouse is ready (standalone's Deployment, or the operator's installation), its Service has ready
#     endpoints and serves no plaintext port, and the schema Job completed
#   - with a standalone ClickHouse, its certificate verifies through the clickhouse Service against the platform's CA
#     by global.clickhouse.tls.serverName, and does not verify by the cluster-local name it must not carry
#   - no pod waits on a missing Secret or is stuck on Vault injection (a vault-agent-init that has not exited 0, or
#     a vault-agent container in CrashLoopBackOff), and no pod creation is refused by the quota or by admission: a ReplicaSet
#     with a ReplicaFailure, or a FailedCreate event in the last ACCEPTANCE_EVENT_WINDOW for an unfinished Job or
#     an unready StatefulSet
#   - a synthetic trace, log and metric go through the OTLP endpoint and are read back through Cerberus and
#     through Grafana's Tempo, Loki and Prometheus datasources
# It then writes a short report (REPORT, by default dist/acceptance/<env>-<UTC time>.md): the context, namespace,
# timestamps, every outcome, and the revisions deployed (the checkout's commit, each Application's revision, each
# workload's images and how its credentials reach it), the secret-delivery owner (SECRET_OWNER) and the revision to
# roll back to (ROLLBACK_REVISION). Nothing in it is a credential, and no response body goes into it.
#
# Without a value of its own, each endpoint is a kubectl port-forward to the Service in the namespace:
#   OTLP_ENDPOINT  OTLP over HTTP, e.g. https://otlp.example (default svc/otel-collector:4318); OTLP_TOKEN, if
#                  set, is sent as a bearer token
#   CERBERUS_URL   default svc/cerberus:8080
#   GRAFANA_URL    default svc/grafana:80. Grafana needs a login the operator supplies, since this never reads a
#                  Secret: GRAFANA_TOKEN (a service account token) or GRAFANA_AUTH (user:password). Without one the
#                  Grafana checks fail.
# CA_FILE is the CA bundle to verify ClickHouse's certificate with, for a platform that keeps it in Vault
# (global.clickhouse.tls.vault); otherwise it is read from the ConfigMap global.clickhouse.tls.caConfigMap.
# NAMESPACE overrides the environment's namespace; ACCEPTANCE_TIMEOUT (300) is how long, in seconds, each signal
# has to be read back; ACCEPTANCE_EVENT_WINDOW (900) is how far back, in seconds, a refusal event counts.
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: acceptance.bash <env>}
values="cluster-configs/overrides/values-$env.yaml"
[[ -f "$values" ]] || { echo "acceptance: no $values; is $env an environment?" >&2; exit 2; }
ns="${NAMESPACE:-$(yq '.namespace // ""' "$values")}"
[[ -n "$ns" ]] || ns="$(yq '.namespace' cluster-configs/app-of-apps/values.yaml)"
timeout=${ACCEPTANCE_TIMEOUT:-300}
event_window=${ACCEPTANCE_EVENT_WINDOW:-900}
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
report="${REPORT:-dist/acceptance/$env-$(date -u +%Y%m%dT%H%M%SZ).md}"

global() {
  local v
  v="$(yq "$1 // \"\"" "$values")"
  [[ -n "$v" ]] || v="$(yq "$1 // \"\"" helm-templates/common/values.yaml)"
  echo "$v"
}
standalone="$(global .global.clickhouse.standalone)"
external="$(global .global.clickhouse.external)"
clickhouse_address="$(global .global.services.clickhouse)"
server_name="$(global .global.clickhouse.tls.serverName)"
ca_configmap="$(global .global.clickhouse.tls.caConfigMap)"
ca_key="$(global .global.clickhouse.tls.caKey)"
clickhouse_service="${clickhouse_address%%:*}"

work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

context="$(kubectl config current-context 2>/dev/null || echo unknown)"
kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1 ||
  { echo "acceptance: context $context cannot read namespace $ns" >&2; exit 2; }
echo "==> Acceptance for $env in namespace $ns, context $context, at $started"

results=()
failures=0
# record <PASS|FAIL|SKIP> <check> <detail>: names and counts only, never a value read from the cluster's data.
record() {
  results+=("$1"$'\t'"$2"$'\t'"$3")
  [[ "$1" != FAIL ]] || failures=$((failures + 1))
  echo "$1: $2${3:+ | $3}"
}
# lines <text>: the lines of <text>, joined by "; ", for a detail.
lines() { paste -sd';' <<<"$1" | sed 's/;/; /g'; }
# forward <var> <service> <port>: port-forward to the Service on a free local port, and set <var> to its URL.
forward() {
  local log="$work/forward-$2.log" port="" _
  kubectl -n "$ns" port-forward "svc/$2" ":$3" >"$log" 2>&1 &
  for _ in $(seq 50); do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -1)"
    [[ -z "$port" ]] || break
    sleep 0.2
  done
  [[ -n "$port" ]] || { printf -v "$1" '%s' ""; echo "  port-forward to svc/$2: $(head -1 "$log")"; return 0; }
  printf -v "$1" 'http://127.0.0.1:%s' "$port"
}

# ---- Argo CD Applications and workloads ----
applications=""
if kubectl -n argocd get applications -o json >"$work/applications.json" 2>/dev/null; then
  applications="$(jq -r --arg env "$env" '.items[]
    | select(.metadata.labels.environment == $env or .metadata.name == "app-of-apps-\($env)")
    | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown"),
       (.spec.source.targetRevision // .spec.sources[0].targetRevision // "-"),
       (.status.sync.revision // .status.sync.revisions[0] // "-")] | @tsv' "$work/applications.json")"
fi
if [[ -n "$applications" ]]; then
  unhealthy="$(awk -F'\t' '$2 != "Synced" || $3 != "Healthy" { print $1 " is " $2 "/" $3 }' <<<"$applications")"
  if [[ -z "$unhealthy" ]]; then
    record PASS "Argo CD: every Application of $env is Synced and Healthy" "$(wc -l <<<"$applications") Applications"
  else
    record FAIL "Argo CD: every Application of $env is Synced and Healthy" "$(lines "$unhealthy")"
  fi
else
  record SKIP "Argo CD: every Application of $env is Synced and Healthy" "no Application of $env readable from this context; the workloads are checked instead"
fi

kubectl -n "$ns" get deployments,statefulsets -o json >"$work/workloads.json"
not_ready="$(jq -r '.items[] | (.spec.replicas // 1) as $want
  | select((.status.readyReplicas // 0) < $want or (.status.updatedReplicas // 0) < $want)
  | "\(.kind)/\(.metadata.name) has \(.status.readyReplicas // 0)/\($want) ready"' "$work/workloads.json")"
count="$(jq '.items | length' "$work/workloads.json")"
if ((count == 0)); then
  record FAIL "Workloads: every Deployment and StatefulSet in $ns is ready" "there are none"
elif [[ -z "$not_ready" ]]; then
  record PASS "Workloads: every Deployment and StatefulSet in $ns is ready" "$count workloads"
else
  record FAIL "Workloads: every Deployment and StatefulSet in $ns is ready" "$(lines "$not_ready")"
fi

kubectl -n "$ns" get jobs -o json >"$work/jobs.json"
failed_jobs="$(jq -r '.items[] | select(any(.status.conditions[]?; .type == "Failed" and .status == "True"))
  | "job/\(.metadata.name): \([.status.conditions[] | select(.type == "Failed") | .reason] | first)"' "$work/jobs.json")"
if [[ -z "$failed_jobs" ]]; then
  record PASS "Workloads: no Job in $ns has failed" "$(jq '.items | length' "$work/jobs.json") Jobs"
else
  record FAIL "Workloads: no Job in $ns has failed" "$(lines "$failed_jobs")"
fi

# ---- ClickHouse ----
if [[ "$external" == true ]]; then
  record SKIP "ClickHouse: ready" "external, at $clickhouse_address: its availability is the service owner's"
elif [[ "$standalone" == true ]]; then
  available="$(kubectl -n "$ns" get deployment clickhouse \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$available" == True ]]; then
    record PASS "ClickHouse: ready" "deployment/clickhouse Available"
  else
    record FAIL "ClickHouse: ready" "deployment/clickhouse is not Available (${available:-missing})"
  fi
else
  chi_status="$(kubectl -n "$ns" get chi otel -o jsonpath='{.status.status}' 2>/dev/null || true)"
  pods="$(kubectl -n "$ns" get pods -l clickhouse.altinity.com/chi=otel -o json |
    jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length as $r
      | "\($r)/\(.items | length)"' 2>/dev/null || echo 0/0)"
  if [[ "$chi_status" == Completed && "${pods%%/*}" == "${pods##*/}" && "${pods%%/*}" != 0 ]]; then
    record PASS "ClickHouse: ready" "installation otel Completed, $pods pods Ready"
  else
    record FAIL "ClickHouse: ready" "installation otel is ${chi_status:-missing}, $pods pods Ready"
  fi
fi

if [[ "$external" == true ]]; then
  record SKIP "ClickHouse: Service $clickhouse_service has ready endpoints" "external"
  record SKIP "ClickHouse: Service $clickhouse_service serves no plaintext port" "external: the clients dial $clickhouse_address with verified TLS (README: An external ClickHouse)"
else
  ready_endpoints="$(kubectl -n "$ns" get endpointslices -l "kubernetes.io/service-name=$clickhouse_service" -o json |
    jq '[.items[].endpoints[]? | select(.conditions.ready != false)] | length')"
  if ((ready_endpoints > 0)); then
    record PASS "ClickHouse: Service $clickhouse_service has ready endpoints" "$ready_endpoints ready"
  else
    record FAIL "ClickHouse: Service $clickhouse_service has ready endpoints" "none ready"
  fi
  if ports="$(kubectl -n "$ns" get service "$clickhouse_service" -o json 2>/dev/null |
    jq -r '[.spec.ports[] | .port, .targetPort] | map(tostring) | unique | join(" ")')"; then
    plaintext=""
    for port in 9000 8123 9004 9005 9009; do
      [[ " $ports " != *" $port "* ]] || plaintext+=" $port"
    done
    if [[ -z "$plaintext" ]]; then
      record PASS "ClickHouse: Service $clickhouse_service serves no plaintext port" "ports $ports"
    else
      record FAIL "ClickHouse: Service $clickhouse_service serves no plaintext port" "plaintext:$plaintext"
    fi
  else
    record FAIL "ClickHouse: Service $clickhouse_service serves no plaintext port" "no Service $clickhouse_service"
  fi
fi

# The server's certificate, through a port-forward to the Service's native TLS port, with openssl: it must verify
# against the platform's CA by serverName, and must not verify by the cluster-local name, which the certificate
# should not carry (README: A standalone ClickHouse). Only the verification result is kept, never the certificate.
tls_check="ClickHouse: the server's certificate verifies as ${server_name:-<serverName>} against the platform's CA"
wrong_name="$clickhouse_service.$ns.svc.cluster.local"
wrong_check="ClickHouse: the server's certificate does not verify as $wrong_name"
if [[ "$standalone" != true ]]; then
  record SKIP "$tls_check" "only a standalone ClickHouse is checked here"
  record SKIP "$wrong_check" "only a standalone ClickHouse is checked here"
else
  ca=""
  if [[ -n "${CA_FILE:-}" ]]; then
    ca="$CA_FILE"
  elif [[ -n "$ca_configmap" ]] && kubectl -n "$ns" get configmap "$ca_configmap" -o json 2>/dev/null |
    jq -er --arg key "${ca_key:-ca.crt}" '.data[$key] // empty' >"$work/ca.crt"; then
    ca="$work/ca.crt"
  fi
  tls_port=""
  if [[ -n "$ca" ]]; then
    tls_forward=""
    forward tls_forward "$clickhouse_service" 9440
    tls_port="${tls_forward##*:}"
  fi
  # verifies <name>: the handshake succeeds with the certificate verified for <name>.
  verifies() {
    openssl s_client -connect "127.0.0.1:$tls_port" -servername "$1" -verify_hostname "$1" -CAfile "$ca" \
      -verify_return_error </dev/null 2>&1 | grep -q 'Verify return code: 0 (ok)'
  }
  if [[ -z "$ca" ]]; then
    record FAIL "$tls_check" "no CA bundle: set CA_FILE, or check ConfigMap ${ca_configmap:-<caConfigMap>} key ${ca_key:-ca.crt}"
    record FAIL "$wrong_check" "no CA bundle"
  elif [[ -z "$tls_port" ]]; then
    record FAIL "$tls_check" "no port-forward to svc/$clickhouse_service:9440"
    record FAIL "$wrong_check" "no port-forward to svc/$clickhouse_service:9440"
  else
    if verifies "$server_name"; then
      record PASS "$tls_check" "svc/$clickhouse_service:9440"
    else
      record FAIL "$tls_check" "refused: wrong CA, expired, or not issued for $server_name"
    fi
    if verifies "$wrong_name"; then
      record FAIL "$wrong_check" "it does: the certificate carries a name clients are not meant to use"
    else
      record PASS "$wrong_check" "refused"
    fi
  fi
fi

schema="$(jq -r '[.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "clickhouse-schema")
  | "\(.metadata.name) \(if any(.status.conditions[]?; .type == "Complete" and .status == "True") then "Complete"
      elif any(.status.conditions[]?; .type == "Failed" and .status == "True") then "Failed" else "running" end)"]
  | join("; ")' "$work/jobs.json")"
if [[ "$schema" == *Complete* ]]; then
  record PASS "ClickHouse: the schema Job completed" "$schema"
else
  record FAIL "ClickHouse: the schema Job completed" "${schema:-no clickhouse-schema Job in $ns}"
fi

# ---- Missing Secrets and refused pods ----
kubectl -n "$ns" get pods -o json >"$work/pods.json"
kubectl -n "$ns" get events -o json >"$work/events.json"
missing="$(jq -r --slurpfile events "$work/events.json" '
  [.items[] | select(.status.phase == "Pending") | .metadata.name] as $pending
  | (.items[] | .metadata.name as $pod
      | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
      | select(.state.waiting.reason == "CreateContainerConfigError" and (.state.waiting.message // "" | test("secret"; "i")))
      | "pod/\($pod): \(.state.waiting.message)"),
    ($events[0].items[] | select(.involvedObject.kind == "Pod" and .reason == "FailedMount"
        and (.involvedObject.name | IN($pending[])) and (.message | test("secret"; "i")))
      | "pod/\(.involvedObject.name): \(.message | split("\n")[0])")' "$work/pods.json" | sort -u)"
if [[ -z "$missing" ]]; then
  record PASS "Secrets: no pod waits on a missing Secret" "$(jq '.items | length' "$work/pods.json") pods"
else
  record FAIL "Secrets: no pod waits on a missing Secret" "$(lines "$missing")"
fi

# A pod the Vault Agent Injector mutated waits in vault-agent-init until the agent has read every record it needs:
# one that hasn't exited 0 is stuck (a role, policy or path Vault refuses, or no route to Vault). Its logs are never
# read here; kubectl logs <pod> -c vault-agent-init names the cause.
injected="$(jq '[.items[] | select(any(.spec.initContainers[]?; .name == "vault-agent-init")
  or any(.spec.containers[]?; .name == "vault-agent"))] | length' "$work/pods.json")"
stuck="$(jq -r '.items[] | .metadata.name as $pod
  | ((.status.initContainerStatuses // [])[] | select(.name == "vault-agent-init")
      | select((.state.terminated.exitCode // -1) != 0)
      | "pod/\($pod): vault-agent-init \(.state.waiting.reason // (if .state.terminated then "exited \(.state.terminated.exitCode)" else "still running" end))"),
    ((.status.containerStatuses // [])[] | select(.name == "vault-agent" and .state.waiting.reason == "CrashLoopBackOff")
      | "pod/\($pod): vault-agent CrashLoopBackOff")' "$work/pods.json" | sort -u)"
if [[ -z "$stuck" ]]; then
  record PASS "Vault: no pod is stuck on Vault injection" "$injected injected pods"
else
  record FAIL "Vault: no pod is stuck on Vault injection" "$(lines "$stuck")"
fi

kubectl -n "$ns" get replicasets -o json >"$work/replicasets.json"
# A ReplicaSet keeps a ReplicaFailure condition while the quota refuses its pods. A Job or StatefulSet keeps no such
# condition, so a recent FailedCreate event counts for one that is still short of pods: unfinished, or not ready.
refused="$(jq -r --argjson since "$(($(date +%s) - event_window))" --slurpfile events "$work/events.json" \
  --slurpfile jobs "$work/jobs.json" --slurpfile workloads "$work/workloads.json" '
  ([$jobs[0].items[] | select(any(.status.conditions[]?; .type == "Complete" and .status == "True") | not)
    | "Job/\(.metadata.name)"] + [$workloads[0].items[] | select(.kind == "StatefulSet")
    | select((.status.readyReplicas // 0) < (.spec.replicas // 1)) | "StatefulSet/\(.metadata.name)"]) as $short
  | (.items[] | select((.spec.replicas // 0) > 0)
      | .metadata.name as $rs | .status.conditions[]? | select(.type == "ReplicaFailure" and .status == "True")
      | "replicaset/\($rs): \(.message)"),
    ($events[0].items[] | select(.reason == "FailedCreate" and (.message | test("forbidden|quota"; "i")))
      | select("\(.involvedObject.kind)/\(.involvedObject.name)" | IN($short[]))
      | select((.lastTimestamp // .eventTime // .metadata.creationTimestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $since)
      | "\(.involvedObject.kind | ascii_downcase)/\(.involvedObject.name): \(.message)")' "$work/replicasets.json" | sort -u)"
if [[ -z "$refused" ]]; then
  record PASS "Quota: no pod creation in $ns is refused by the quota or admission" "none"
else
  record FAIL "Quota: no pod creation in $ns is refused by the quota or admission" "$(lines "$refused")"
fi

# ---- Synthetic signals ----
otlp="${OTLP_ENDPOINT:-}"
[[ -n "$otlp" ]] || forward otlp otel-collector 4318
cerberus="${CERBERUS_URL:-}"
[[ -n "$cerberus" ]] || forward cerberus cerberus 8080
grafana="${GRAFANA_URL:-}"
[[ -n "$grafana" ]] || forward grafana grafana 80

probe_service=acceptance-probe
run="$(openssl rand -hex 8)"
trace="$(openssl rand -hex 16)"
t1="$(date +%s%N)"
# The span is named for this run, so its span metrics can't be an earlier run's series, which the collector keeps
# reporting.
span="$(jq -nc --arg svc "$probe_service" --arg run "$run" --arg trace "$trace" --arg span "$(openssl rand -hex 8)" \
  --arg t0 "$((t1 - 20000000))" --arg t1 "$t1" \
  '{resourceSpans: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeSpans: [{spans: [{traceId: $trace, spanId: $span, name: ("GET /acceptance/" + $run), kind: 2,
      startTimeUnixNano: $t0, endTimeUnixNano: $t1}]}]}]}')"
log="$(jq -nc --arg svc "$probe_service" --arg run "$run" --arg t "$t1" --arg trace "$trace" \
  '{resourceLogs: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeLogs: [{logRecords: [{timeUnixNano: $t, severityText: "INFO", traceId: $trace,
      body: {stringValue: ("acceptance probe " + $run)}, attributes: [{key: "run", value: {stringValue: $run}}]}]}]}]}')"
metric="$(jq -nc --arg svc "$probe_service" --arg run "$run" --arg t "$t1" \
  '{resourceMetrics: [{resource: {attributes: [{key: "service.name", value: {stringValue: $svc}}]},
    scopeMetrics: [{metrics: [{name: "acceptance_probe", gauge: {dataPoints: [{timeUnixNano: $t, asDouble: 42,
      attributes: [{key: "run", value: {stringValue: $run}}]}]}}]}]}]}')"

sent=false
if [[ -z "$otlp" ]]; then
  record FAIL "OTLP: the collector accepts a trace, a log and a metric" "no OTLP endpoint"
else
  otlp_auth=()
  [[ -z "${OTLP_TOKEN:-}" ]] || otlp_auth=(-H "Authorization: Bearer $OTLP_TOKEN")
  refused_signals=""
  for pair in "traces:$span" "logs:$log" "metrics:$metric"; do
    curl -fsS -o /dev/null --retry 5 --retry-all-errors --retry-delay 2 -X POST -H 'Content-Type: application/json' \
      "${otlp_auth[@]}" -d "${pair#*:}" "$otlp/v1/${pair%%:*}" 2>/dev/null || refused_signals+=" ${pair%%:*}"
  done
  if [[ -z "$refused_signals" ]]; then
    sent=true
    record PASS "OTLP: the collector accepts a trace, a log and a metric" "run $run, trace $trace"
  else
    record FAIL "OTLP: the collector accepts a trace, a log and a metric" "refused:$refused_signals"
  fi
fi

# read_back <check> <jq check> <curl args...>: poll until the response satisfies the check, or ACCEPTANCE_TIMEOUT.
read_back() {
  local check=$1 test=$2 deadline=$((SECONDS + timeout)) body=""
  shift 2
  if [[ "$sent" != true ]]; then
    record FAIL "$check" "nothing was sent"
    return 0
  fi
  while :; do
    body="$(curl -fsS -G "$@" 2>/dev/null || true)"
    if [[ -n "$body" ]] && jq -e "$test" <<<"$body" >/dev/null 2>&1; then
      record PASS "$check" "run $run"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "  last response: ${body:0:300}"
      record FAIL "$check" "not read back within ${timeout}s"
      return 0
    fi
    sleep 5
  done
}

now="$(date +%s)"
trace_check="[.batches[]?.resource.attributes | if type == \"array\" then (.[] | select(.key == \"service.name\") | .value.stringValue)
  else .[\"service.name\"] end] | index(\"$probe_service\") != null"
log_check="[.data.result[].values[][1]] | index(\"acceptance probe $run\") != null"
metric_check='[.data.result[].value[1] | tonumber] == [42]'
log_query=(--data-urlencode "query={service_name=\"$probe_service\"} | run=\"$run\""
  --data-urlencode "start=$((now - 900))000000000" --data-urlencode "end=$((now + 900))000000000" --data-urlencode 'limit=10')
metric_query=(--data-urlencode "query=acceptance_probe{service_name=\"$probe_service\", run=\"$run\"}")
# The collector's spanmetrics connector turns the synthetic span into a calls counter: what the service dashboard
# and Metrics Drilldown read.
span_metrics_check='[.data.result[].value[1] | tonumber] | length > 0 and all(. >= 1)'
span_metrics_query=(--data-urlencode
  "query=sum(traces_span_metrics_calls{service_name=\"$probe_service\", span_name=\"GET /acceptance/$run\"})")

if [[ -z "$cerberus" ]]; then
  for signal in trace log metric "span's span metrics"; do
    record FAIL "Cerberus: reads the synthetic $signal" "no Cerberus endpoint"
  done
else
  read_back "Cerberus: reads the synthetic trace (TraceQL API)" "$trace_check" "$cerberus/api/traces/$trace"
  read_back "Cerberus: reads the synthetic log (LogQL)" "$log_check" "$cerberus/loki/api/v1/query_range" "${log_query[@]}"
  read_back "Cerberus: reads the synthetic metric (PromQL)" "$metric_check" "$cerberus/api/v1/query" "${metric_query[@]}"
  read_back "Cerberus: reads the synthetic span's span metrics (PromQL)" "$span_metrics_check" "$cerberus/api/v1/query" \
    "${span_metrics_query[@]}"
fi

grafana_auth=()
if [[ -n "${GRAFANA_TOKEN:-}" ]]; then
  grafana_auth=(-H "Authorization: Bearer $GRAFANA_TOKEN")
elif [[ -n "${GRAFANA_AUTH:-}" ]]; then
  grafana_auth=(-u "$GRAFANA_AUTH")
fi
grafana_checks=("Grafana: the Tempo datasource opens the synthetic trace"
  "Grafana: the Loki datasource finds the synthetic log"
  "Grafana: the Prometheus datasource reads the synthetic metric"
  "Grafana: the Prometheus datasource reads the synthetic span's span metrics")
if [[ -z "$grafana" ]]; then
  for check in "${grafana_checks[@]}"; do record FAIL "$check" "no Grafana endpoint"; done
elif ((${#grafana_auth[@]} == 0)); then
  for check in "${grafana_checks[@]}"; do record FAIL "$check" "no GRAFANA_TOKEN or GRAFANA_AUTH given"; done
else
  proxy="$grafana/api/datasources/proxy/uid"
  read_back "${grafana_checks[0]}" "$trace_check" "${grafana_auth[@]}" "$proxy/cerberus-tempo/api/traces/$trace"
  read_back "${grafana_checks[1]}" "$log_check" "${grafana_auth[@]}" "$proxy/cerberus-loki/loki/api/v1/query_range" "${log_query[@]}"
  read_back "${grafana_checks[2]}" "$metric_check" "${grafana_auth[@]}" "$proxy/cerberus-prometheus/api/v1/query" "${metric_query[@]}"
  read_back "${grafana_checks[3]}" "$span_metrics_check" "${grafana_auth[@]}" "$proxy/cerberus-prometheus/api/v1/query" \
    "${span_metrics_query[@]}"
fi

# ---- Report ----
finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || commit+=" (with uncommitted changes)"
passed=0 skipped=0
for r in "${results[@]}"; do
  case "${r%%$'\t'*}" in PASS) passed=$((passed + 1)) ;; SKIP) skipped=$((skipped + 1)) ;; esac
done
verdict=PASS
((failures == 0)) || verdict=FAIL
mkdir -p "$(dirname "$report")"
{
  echo "# Acceptance: $env"
  echo
  echo "- Result: **$verdict**, $passed passed, $failures failed, $skipped skipped"
  echo "- Context: $context; namespace: $ns"
  echo "- Started: $started; finished: $finished"
  echo "- Checkout: $commit; values-$env.yaml: $(yq '.repoURL' "$values") @ $(yq '.targetRevision' "$values")"
  echo "- Secret-delivery owner: ${SECRET_OWNER:-not recorded (SECRET_OWNER)}"
  echo "- Rollback revision: ${ROLLBACK_REVISION:-not recorded (ROLLBACK_REVISION)}"
  echo
  echo "## Checks"
  echo
  echo "| Result | Check | Detail |"
  echo "| --- | --- | --- |"
  for r in "${results[@]}"; do
    IFS=$'\t' read -r outcome check detail <<<"$r"
    echo "| $outcome | $check | ${detail//|/\\|} |"
  done
  echo
  echo "## Deployed revisions"
  echo
  if [[ -n "$applications" ]]; then
    echo "| Application | Sync / health | Target revision | Synced revision |"
    echo "| --- | --- | --- | --- |"
    while IFS=$'\t' read -r name sync health target synced; do
      echo "| $name | $sync / $health | $target | $synced |"
    done <<<"$applications"
  else
    echo "No Argo CD Application of $env is readable from this context."
  fi
  echo
  echo "| Workload | Images | Credentials |"
  echo "| --- | --- | --- |"
  # How credentials reach each workload, from its pod template: the Vault agent, Secrets it references, or neither.
  jq -r '.items[] | .spec.template as $t
    | ([$t.spec.containers[]?.env[]?.valueFrom.secretKeyRef.name, $t.spec.volumes[]?.secret.secretName]
        | map(select(. != null)) | unique) as $secrets
    | (if $t.metadata.annotations["vault.hashicorp.com/agent-inject"] == "true" then "Vault agent"
       elif ($secrets | length) > 0 then "Secrets: \($secrets | join(", "))" else "none" end) as $delivery
    | "| \(.kind)/\(.metadata.name) | \([$t.spec.containers[].image] | join(", ")) | \($delivery) |"' "$work/workloads.json"
} >"$report"

echo "==> Acceptance $verdict: $passed passed, $failures failed, $skipped skipped; report in $report"
((failures == 0))
