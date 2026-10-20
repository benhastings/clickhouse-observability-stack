# Runbook

<!-- cspell:words nettest oneline storageclass toomanyrequests untolerated -->

What to check, how to test, and what to do when something looks wrong. It assumes the stack is installed
([getting started](getting-started.md)) and that `kubectl` points at the right cluster. Every command here is
read-only unless it says otherwise.

Most commands use the `observability` namespace. To avoid typing `-n observability` every time:

```bash
kubectl config set-context --current --namespace=observability
```

## How data moves, and where to look at each step

When something is missing, follow the data from left to right and find the first step where it stops.

| Step | What happens | How to look at it |
|---|---|---|
| 1. An app sends | The app's OpenTelemetry SDK sends OTLP to `otel-collector:4317` (gRPC) or `:4318` (HTTP) | the app's own logs, for export errors |
| 2. The collector receives | It accepts or refuses each batch, adds Kubernetes labels, and batches | `kubectl logs deploy/otel-collector`; **Stack health** dashboard, *accepted / refused* |
| 3. The collector writes | It inserts into ClickHouse as `otel_writer` | **Stack health**, *exporter sent / failed* and *queue*; collector logs |
| 4. ClickHouse stores | Rows land in the `otel` database's tables | the freshness query in the [smoke test](#smoke-test-five-minutes) |
| 5. Cerberus translates | Grafana's PromQL, LogQL and TraceQL become SQL | `kubectl logs deploy/cerberus`; **Stack health**, *Cerberus latency* |
| 6. Grafana shows | Dashboards and Explore query Cerberus | the panel's **Inspect → Query** shows the query and the error |
| 7. Alerts | vmalert runs the rules every minute through garmr and sends what fires to Alertmanager | vmalert and Alertmanager UIs ([Alerts](#alerts)) |

## Daily check (two minutes)

1. **Is everything running?**

   ```bash
   kubectl get pods -n observability
   kubectl get pods -n clickhouse-operator
   kubectl get chi -n observability          # otel should say Completed
   ```

   Every pod should be `Running` with `1/1` (or `Completed` for `clickhouse-schema-...`), and `RESTARTS`
   shouldn't be growing from one day to the next.

2. **Is data arriving?** Open **Dashboards → Cerberus → Stack health**. The *accepted* lines should be flat
   or follow your traffic, and *refused* and *failed* should be zero.

3. **Is anything firing?** Check [Alerts](#alerts). `Watchdog` is always firing, on purpose: it proves the
   alert pipeline works. Anything else deserves a look; see [what each alert means](#what-each-alert-means).

4. **Is the disk OK?** The **Stack health** dashboard, or `ClickHouseDiskFilling`, which warns at 80%.

## Smoke test (five minutes)

This sends a trace and a log of your own, then reads them back through the same path Grafana uses. Run it
after an install, an upgrade, or any change.

In one terminal, open tunnels to the cluster and leave them running:

```bash
make cluster/port-forward      # Grafana :3000, Cerberus :8081, collector :4317/:4318
```

In a second terminal:

```bash
# 1. Send a span: one step of a made-up request, from a service called smoke-test.
trace=$(openssl rand -hex 16); span=$(openssl rand -hex 8); now=$(date +%s%N)
curl -sS -o /dev/null -w 'collector said HTTP %{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[{"resource":{"attributes":[
    {"key":"service.name","value":{"stringValue":"smoke-test"}}]},"scopeSpans":[{"spans":[{
    "traceId":"'$trace'","spanId":"'$span'","name":"hello","kind":2,
    "startTimeUnixNano":"'$((now - 50000000))'","endTimeUnixNano":"'$now'"}]}]}]}'

# 2. Send a log line.
curl -sS -o /dev/null -w 'collector said HTTP %{http_code}\n' -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' -d '{"resourceLogs":[{"resource":{"attributes":[
    {"key":"service.name","value":{"stringValue":"smoke-test"}}]},"scopeLogs":[{"logRecords":[{
    "timeUnixNano":"'$(date +%s%N)'","severityText":"INFO","body":{"stringValue":"hello from the runbook"}}]}]}]}'

sleep 20   # the collector batches for a few seconds before it writes

# 3. Read the trace back, the way Grafana's Tempo datasource does.
curl -sS http://localhost:8081/api/traces/$trace | jq -c '[.. | .name? // empty]'

# 4. Read the log back, the way Grafana's Loki datasource does.
curl -sS -G http://localhost:8081/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="smoke-test"}' \
  --data-urlencode "start=$(($(date +%s) - 600))000000000" --data-urlencode "end=$(date +%s)000000000" |
  jq -c '[.data.result[].values[][1]]'

# 5. Requests per second for each service, from metrics the collector builds out of spans.
curl -sS -G http://localhost:8081/api/v1/query \
  --data-urlencode 'query=sum by (service_name) (rate(traces_span_metrics_calls[5m]))' |
  jq -c '[.data.result[] | {service: .metric.service_name, per_second: .value[1]}]'
```

What you should see:

```text
collector said HTTP 200
collector said HTTP 200
["hello"]
["hello from the runbook"]          (one per run in the last 10 minutes)
[{"service":"web","per_second":"3.99"},{"service":"smoke-test","per_second":"0.0045"},{"service":"payments",...},{"service":"checkout",...}]
```

| If | Then |
|---|---|
| `curl: (7) Failed to connect` | The port-forward isn't running, or it died when a pod restarted. Restart `make cluster/port-forward`. |
| `HTTP 401` | Collector auth is on: add `-H "Authorization: Bearer $token"` with the token from the `otel-collector-auth` Secret. |
| Step 3 or 4 prints `[]` | Wait another 30 seconds and run it again. If it's still empty, follow [No data in Grafana](#no-data-in-grafana). |
| Step 5 has no `web`, `checkout` or `payments` | The demo load isn't running, or is turned off in your environment file. |

Then check from inside ClickHouse that every kind of data is fresh and the disk has room:

```bash
pw=$(kubectl -n observability get secret clickhouse-reader -o go-template='{{.data.password | base64decode}}')
kubectl -n observability exec chi-otel-main-0-0-0 -c clickhouse -- \
  clickhouse-client --user otel_reader --password "$pw" --format PrettyCompact -q "
    SELECT 'traces' AS signal, count() AS last_5_min, max(Timestamp) AS newest FROM otel.otel_traces WHERE Timestamp > now() - INTERVAL 5 MINUTE
    UNION ALL SELECT 'logs', count(), max(Timestamp) FROM otel.otel_logs WHERE Timestamp > now() - INTERVAL 5 MINUTE
    UNION ALL SELECT 'metrics', count(), max(TimeUnix) FROM otel.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 5 MINUTE"
```

Each row should have a count above zero and a `newest` within the last minute. Times are UTC.

Last, the alert pipeline: `Watchdog` should be firing (see [Alerts](#alerts)).

Grafana's three Cerberus datasources can check themselves too: **Connections → Data sources**, open each one,
and press **Save & test**.

## Alerts

vmalert checks the rules in `cluster-nodes/vmalert/files/rules/` every minute and sends what fires to
Alertmanager. Grafana has a few starter rules of its own, which go to the same Alertmanager.

**Out of the box, Alertmanager sends alerts nowhere.** It receives them, groups them and keeps them, but no
one is notified until an environment adds a receiver. Slack is built in: see **Slack: one thread per alert
group** in the README. Until then, look at alerts in one of these places:

```bash
kubectl -n observability port-forward svc/alertmanager 9093:9093    # then open http://localhost:9093
kubectl -n observability port-forward svc/vmalert 8880:8880         # then open http://localhost:8880
```

- **Alertmanager's page** (`:9093`) lists what is firing now, grouped, and lets you silence an alert.
- **vmalert's page** (`:8880`) lists every rule, its last result, and any rule that errors.
- **In Grafana**, every notification Alertmanager handles is kept as a log line: Explore → **Loki (Cerberus)**
  → `{service_name="alertmanager"}`. The **Alert hygiene** dashboard counts them, and the Span metrics
  dashboard marks them on its charts (red when firing, green when resolved).

From the command line, with those port-forwards running:

```bash
curl -sS http://localhost:9093/api/v2/alerts | jq -r '.[] | "\(.labels.alertname) \(.labels.service_name // "") \(.status.state)"'
curl -sS http://localhost:8880/api/v1/rules | jq -r '[.data.groups[].rules[].health] | group_by(.) | map("\(.[0]): \(length)") | join(", ")'
```

The second command should print only `ok: <number>`. An `err` means a rule's query fails; vmalert's page shows
the error.

### What each alert means

`critical` should get someone's attention now, `warning` during working hours. With the demo load running,
`ErrorRatioAnomaly`, `AvailabilityBudgetBurn` and `LatencyBudgetBurn` for `payments` fire every hour, because
of its scheduled incident. That's the demo working, not a problem.

**About your services:**

| Alert | Severity | Meaning | First thing to check |
|---|---|---|---|
| `TelemetryAbsent` | critical | A service that was sending spans has sent none for 5 minutes | Is the service running? Did its pods restart? Then look at the collector, step 2 above |
| `AvailabilityBudgetBurn` | critical (1h, 6h), warning (3d) | The service fails often enough to use up a month of its allowed errors early. The default objective is 95% of requests succeeding | **SLOs** dashboard; then the service's failing traces in Explore → Tempo: `{resource.service.name="<service>" && status=error}` |
| `LatencyBudgetBurn` | critical (1h, 6h), warning (3d) | The same, for requests slower than the service's threshold | **SLOs** dashboard; slow traces: `{resource.service.name="<service>" && duration > 1s}` |
| `ErrorRatioAnomaly` | warning | The share of failing requests is far above normal for this hour of the week | **Span metrics (RED)**, *Error rate*; click the line for its traces and logs |
| `LatencyAnomaly` | warning | p95 latency (the time 95% of requests finish within) is far above normal | **Span metrics (RED)**, *Latency*, and its heatmap |
| `RequestRateAnomaly` | warning | Traffic is far above or below normal for this hour of the week | Was there a deploy, an outage upstream, or a marketing email? |
| `ErrorLogAnomaly` | warning | The service writes far more error logs than normal | Explore → Loki: `{service_name="<service>"} \| detected_level="error"` |

The anomaly alerts compare each minute with what's normal for that service. Once there are two weeks of
history, normal means the same hour of the week. Until then it means the hour before, so a sudden change still
fires on a new install, but a slow daily pattern can't be told apart from a problem yet.

**About the stack itself:**

| Alert | Severity | Meaning | First thing to check |
|---|---|---|---|
| `Watchdog` | none | Always firing. It proves vmalert evaluates rules and Alertmanager receives them | If it's *missing*, alerting is broken: check the `vmalert`, `garmr-sql-adapter` and `alertmanager` pods and logs |
| `CollectorExportFailing` | critical | The collector couldn't write to ClickHouse and dropped data | `kubectl logs deploy/otel-collector \| grep -i error`; is ClickHouse running? |
| `CollectorExportQueueFull` | warning | Writes to ClickHouse are falling behind | ClickHouse's CPU and memory on **Stack health**; the next alert down is often the cause |
| `CollectorRefusingData` | warning | The collector rejected data from senders | Its logs; usually memory, see the next row |
| `CollectorMemoryLimiterRefusing` | warning | The collector is near its memory limit and is refusing data to protect itself | Raise its memory limit (and `GOMEMLIMIT`, 80% of it) in your environment file |
| `CollectorMemoryNearLimit` | warning | The collector's memory is close to its container limit | The same, before it starts refusing |
| `ClickHouseDiskFilling` | warning | The ClickHouse disk is over 80% full | [Disk filling up](#disk-filling-up) |
| `ClickHouseDiskFull` | critical | Over 90%: inserts will start failing soon | The same, now |
| `ClickHouseInsertsFailing` | warning | More than 1% of writes into ClickHouse fail | `kubectl logs chi-otel-main-0-0-0 -c clickhouse \| grep -i error \| tail` |
| `ClickHouseMemoryLimitRejects` | warning | ClickHouse turned queries or writes away for lack of memory | [ClickHouse out of memory](#clickhouse-out-of-memory) |
| `ClickHouseTooManyParts` | warning | ClickHouse can't merge fast enough. Usually CPU-starved, or too many small writes | Raise ClickHouse's CPU request |
| `SpanMetricsCardinalityLimitHit` | warning | A service creates too many distinct metric series, usually an ID in a span name or route | Ask the service's owners to remove IDs from span names; see **Cardinality** in the README |
| `BaselineRefreshFailing` | warning | The views behind the anomaly alerts stopped refreshing, so those alerts go blind | ClickHouse's logs; `SELECT view, status, exception FROM system.view_refreshes` as `otel_admin` |
| `AlertmanagerNotificationsFailing` | critical | Alertmanager couldn't deliver to Slack (or another receiver) | `kubectl logs deploy/alertmanager`; is the token Secret right? |

## Fixes by symptom

Three commands answer most "why isn't it working" questions. Learn these first:

```bash
kubectl get pods                         # what state is everything in?
kubectl describe pod <pod-name>          # why? Read the Events section at the bottom.
kubectl logs <pod-name> [-c <container>] [--previous]   # what did the program say? --previous is the run before the last restart
```

`kubectl get events --sort-by=.lastTimestamp | tail -20` shows the namespace's recent events: scheduling,
image pulls, kills. The same events are stored as logs:
`{service_name="kubernetes-events"}` in Explore → Loki shows them going back days.

### A pod is `Pending`

Kubernetes hasn't found a place to run it. `kubectl describe pod <pod>`, then read **Events**:

- `Insufficient memory` or `Insufficient cpu`: no node has that much free. Check with
  `kubectl describe nodes | grep -A8 'Allocated resources'`. Lower the request in your environment file, or
  add a node.
- `pod has unbound immediate PersistentVolumeClaims`: the disk hasn't been created. Run `kubectl get pvc`.
  If `data-chi-otel-main-0-0-0` is `Pending`, `kubectl describe pvc data-chi-otel-main-0-0-0` says why,
  usually no default StorageClass or a size the StorageClass can't provide. Set
  `clickhouse.storageClassName` in your environment file.
- `didn't match Pod's node affinity/selector` or `untolerated taint`: the nodes are reserved for something
  else. Ask whoever runs the cluster which nodes you may use.

### A pod is in `ImagePullBackOff` or `ErrImagePull`

The node couldn't download the container image. `kubectl describe pod <pod>` shows the image and the error:

- `not found`: the tag doesn't exist. Check the image in `cluster-nodes/<app>/values.yaml`.
- `toomanyrequests` or `rate limit`: the registry is throttling anonymous pulls. Wait, or use a mirror.
- `i/o timeout`, `connection refused` or `x509`: the nodes can't reach the registry, often because of a
  proxy or firewall. Set `global.imageRegistry: registry.example/mirror` in your environment file to pull
  everything through a mirror your nodes can reach (see `helm-templates/common/README.md`).

### A pod is in `CrashLoopBackOff`, or `RESTARTS` keeps going up

The program starts and then exits, again and again. First find out how it ended:

```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState}' ; echo
kubectl logs <pod> --previous | tail -50
```

- `"reason":"OOMKilled"`: it used more memory than its limit, and the kernel killed it, the same as the
  Linux OOM killer. Raise `resources.limits.memory` for that app in your environment file, along with its
  `GOMEMLIMIT` (80% of the limit) for the Go programs: the collector, Cerberus and Grafana.
- `"reason":"Error"` with an exit code: the log says why. Common ones:
  - **Cerberus** or **the collector** with `connection refused` to `clickhouse:9000`: ClickHouse isn't up yet.
    It settles once ClickHouse is `Running`.
  - `ACCESS_DENIED` or `Authentication failed`: a Secret's password doesn't match what ClickHouse was
    created with. This happens if a Secret was deleted and recreated with a new password. Put the old one
    back, or restart ClickHouse and then the app so both read the new one:
    `kubectl delete pod chi-otel-main-0-0-0`, wait for it to be `Running`, then
    `kubectl rollout restart deploy/<app>`.

### ClickHouse never appears

`chi-otel-main-0-0-0` isn't in `kubectl get pods`:

```bash
kubectl get chi otel -o jsonpath='{.status.status} {.status.errors}' ; echo
kubectl -n clickhouse-operator logs deploy/clickhouse-operator --tail=50
```

- No `chi otel` at all: the install didn't get that far. Re-run `make helm/install`, or look at the `clickhouse`
  Application in Argo CD.
- `InProgress` for a long time: the operator is waiting on something, usually the disk (see
  [Pending](#a-pod-is-pending)).
- An error mentioning a Secret: `clickhouse-operator-credentials` (in the `clickhouse-operator` namespace) or a
  `clickhouse-*` Secret is missing. Run `make cluster/preflight ENV=<env>`.

### Cerberus stays `0/1`

Cerberus reports ready only once the tables exist, and the `clickhouse-schema-...` job creates them:

```bash
kubectl get jobs
kubectl logs job/$(kubectl get jobs -o name | grep clickhouse-schema | tail -1 | cut -d/ -f2)
kubectl logs deploy/cerberus --tail=30
```

A schema job that failed says why at the end of its log. It runs again on the next `helm/install` or Argo CD
sync.

### No data in Grafana

Work along [the steps](#how-data-moves-and-where-to-look-at-each-step) until you find where it stops:

1. **The time range.** It's at the top right of every dashboard. Is it *Last 1 hour*, and are there spans
   from that hour? A new install has no data from before it existed.
2. **The datasources.** **Connections → Data sources → Cerberus Prometheus / Loki / Tempo → Save & test.**
   A failure here means Grafana can't reach Cerberus: `kubectl get pods`, then `kubectl logs deploy/cerberus`.
3. **The data.** Run the freshness query from the [smoke test](#smoke-test-five-minutes). Rows there but not in
   Grafana means it's the query, so open the panel's menu, **Inspect → Query**, and read the error. No rows
   means the data never arrived; carry on.
4. **The collector.** `kubectl logs deploy/otel-collector --tail=100 | grep -iE 'error|refused|denied'`.
   On **Stack health**: is *accepted* above zero? Are *refused* or *failed* above zero?
5. **The sender.** Is your app pointed at `http://otel-collector.observability:4318` with
   `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, or at `:4317` with `grpc`? Mixing them, gRPC to 4318 or HTTP
   to 4317, fails quietly in some SDKs. Run the smoke test's step 1 from inside the app's pod, to rule out the
   network:

   ```bash
   kubectl -n <app-namespace> exec deploy/<app> -- \
     curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://otel-collector.observability:4318/v1/traces \
     -H 'Content-Type: application/json' -d '{}'
   ```

   `200` or `400` means the collector is reachable (an empty body is a bad request, but it got there). A
   timeout points at a NetworkPolicy; see **Before using this beyond a laptop** in the README. Many app
   images have no `curl`. In that case, start a throwaway pod in the app's namespace:
   `kubectl -n <app-namespace> run nettest --rm -it --restart=Never --image=curlimages/curl -- sh`.

### Disk filling up

How full, and what's using it:

```bash
pw=$(kubectl get secret clickhouse-admin -o go-template='{{.data.password | base64decode}}')
kubectl exec chi-otel-main-0-0-0 -c clickhouse -- clickhouse-client --user otel_admin --password "$pw" \
  --format PrettyCompact -q "
    SELECT formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total FROM system.disks;
    SELECT table, formatReadableQuantity(sum(rows)) AS rows, formatReadableSize(sum(bytes_on_disk)) AS on_disk
    FROM system.parts WHERE active AND database = 'otel' GROUP BY table ORDER BY sum(bytes_on_disk) DESC"
```

Then pick one or more fixes:

- **Keep less.** Lower `clickhouse.schema.ttlDays` in your environment file and apply it. ClickHouse drops whole
  days at a time, so the space comes back within a day.
- **A bigger disk.** If `kubectl get storageclass <name> -o jsonpath='{.allowVolumeExpansion}'` says `true`,
  raise `clickhouse.storage` and apply. The operator asks for the bigger volume. Some storage drivers only
  finish growing it after the pod restarts (`kubectl delete pod chi-otel-main-0-0-0`).
- **Send less.** The table above shows which kind of data takes the space. Very chatty debug logs are the usual
  culprit.

The README's **Disk sizing** has the arithmetic for choosing a size.

### ClickHouse out of memory

`ClickHouseMemoryLimitRejects` fires, or queries fail with `MEMORY_LIMIT_EXCEEDED`. ClickHouse caps itself at
90% of its container limit, and counts its own program code (about 460 MiB) against that cap. Raise
`clickhouse.resources` (request and limit together) in your environment file. If the rejects come from one
heavy dashboard or notebook query, narrowing its time range is the quicker fix.

### The port-forward stopped working

`kubectl port-forward` is tied to the pod it started with. When that pod restarts or is replaced, for example
after a config change, the tunnel dies (`lost connection to pod`). Stop it with Ctrl+C and start it again.

### Grafana restarts when someone opens a Drilldown app

Look for `OOMKilled` (see [CrashLoopBackOff](#a-pod-is-in-crashloopbackoff-or-restarts-keeps-going-up)).
Metrics Drilldown sends many queries at once through Grafana's server. Raise Grafana's memory limit.

## Making a change safely

1. Edit `cluster-configs/overrides/values-<env>.yaml`.
2. `make helm/template ENV=<env>` and look at what changed under `dist/helm/<env>/`: this is the exact YAML
   that will be applied.
3. Apply: `make helm/install ENV=<env>` (Helm), or commit and push to the environment's branch (Argo CD).
4. Watch the pods roll: `kubectl get pods -w`.
5. Run the [smoke test](#smoke-test-five-minutes).

To undo a Helm change: `helm -n observability history stack`, then `helm -n observability rollback stack <revision>`.
With Argo CD, revert the commit and push.

## Cheat sheet

| I want to | Run |
|---|---|
| see everything | `kubectl get pods,svc,pvc,jobs -n observability` |
| follow a program's log | `kubectl logs -f deploy/otel-collector` (or `cerberus`, `grafana`, `vmalert`, ...) |
| read ClickHouse's log | `kubectl logs chi-otel-main-0-0-0 -c clickhouse --tail=100` |
| restart one app | `kubectl rollout restart deploy/<app>` (changes the cluster) |
| open a SQL prompt, read-only | `kubectl exec -it chi-otel-main-0-0-0 -c clickhouse -- clickhouse-client --user otel_reader --password "$(kubectl get secret clickhouse-reader -o go-template='{{.data.password \| base64decode}}')"` |
| get the Grafana password | `kubectl get secret grafana-admin -o go-template='{{index .data "admin-password" \| base64decode}}'` |
| see CPU and memory per pod | **Dashboards → Cerberus → Kubernetes**, or `kubectl top pods` if metrics-server is installed |
| see what Helm installed | `helm -n observability list`, `helm -n observability get values stack` |
| check config before applying | `make cluster/preflight ENV=<env>`, `make helm/template ENV=<env>` |

## Asking for help

Include these, and most problems can be diagnosed without a call:

```bash
kubectl get pods -A -o wide
kubectl -n observability get chi,pvc,jobs
kubectl -n observability get events --sort-by=.lastTimestamp | tail -40
kubectl -n observability describe pod <the pod that's unhappy>
kubectl -n observability logs <the pod that's unhappy> --tail=200 [--previous]
git -C <your clone> log -1 --oneline      # which version of this repository
```

Also include your `values-<env>.yaml`. It has no passwords in it, but check before you paste it anywhere
public.
