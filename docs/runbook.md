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

- **Keep less.** Lower `global.retention` in your environment file and apply it. ClickHouse drops whole
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

### A stale child Application stays `OutOfSync`

A child Application the environment no longer renders, typically `clickhouse-operator-<env>` left behind after
an environment moved to a shared operator, an external ClickHouse or a standalone ClickHouse. It stays
`OutOfSync` and Argo CD keeps retrying objects the project forbids: the operator's CRDs, ClusterRole and
ClusterRoleBinding. No `clusterScoped: false` environment renders an operator Application any more (the render
fails on `enabled: true`, and `make check/restricted` fails on one in the golden render), so this only needs doing
once per environment that has one.

Every child carries the `resources-finalizer.argocd.argoproj.io` finalizer: deleting it, or letting the parent
prune it, deletes everything it manages. For the operator that can include CRDs, and deleting a CRD deletes every
ClickHouseInstallation in the cluster, the platform's included. So look before you delete:

1. Check what its finalizer would delete. `argocd app resources clickhouse-operator-<env>` lists every object it
   manages, and `argocd app get clickhouse-operator-<env>` shows which of them exist (anything not `Missing`).
   In a restricted namespace the cluster-scoped ones should be `Missing`, because the project never let Argo CD
   create them, but an object with the same name may belong to someone else, such as the platform's CRDs.
2. If anything it manages exists, or you are not sure, delete only the Application, with no cascade, so nothing
   it manages is pruned (this changes the cluster):

   ```bash
   argocd app delete clickhouse-operator-<env> --cascade=false
   ```

   Without the `argocd` CLI, remove the finalizer, then delete the Application:
   `kubectl -n argocd patch application clickhouse-operator-<env> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`,
   then `kubectl -n argocd delete application clickhouse-operator-<env>`. Deleting Applications in `argocd` may
   need the platform team. Remove what is left of the operator in your own namespace by hand, once you have
   checked it is yours.
3. Confirm the parent prunes it: `argocd app get app-of-apps-<env>` is `Synced`, with no
   `clickhouse-operator-<env>` among its resources, and
   `kubectl -n argocd get applications -l environment=<env>` no longer lists it.

Never broaden the AppProject to let the stale child sync. Its `clusterResourceWhitelist` is the namespace's
boundary; the fix is to remove the child, not the boundary.

### Recovering a parent that fails to render

The parent `app-of-apps-<env>` renders every child Application from `values-<env>.yaml`. When that render fails (a
Helm validation error, such as Vault and External Secrets both on for one app), the parent can no longer change
any child: it can't disable one, reconfigure one or prune one. Each child keeps its last spec, and if that spec
follows a branch, some children update from it while others never get the change they need. A child the parent
should have removed, such as a stale `clickhouse-operator-<env>`, keeps retrying CRDs the project refuses.
Retrying a sync never fixes a render error. Recover in this order:

1. **Stop the movement.** Pin each child that follows a branch to the last commit that worked, for this recovery
   only: `argocd app set <child> --revision <sha>` (with the parent's self-heal off for the duration, as in
   [Pausing a failing Application](#pausing-a-failing-application)). `argocd app history <child>` shows what it last
   deployed. This changes the cluster.
2. **Fix the values and the source together.** In one reviewable change, make `values-<env>.yaml` render against
   the chart at the revision it names, and set that revision (`targetRevision` in `values-<env>.yaml` and in
   `app-of-apps-<env>.yaml`) to a commit SHA or a tag, never a branch.
3. **Prove the render before anything syncs.** `make cluster/preflight ENV=<env>` renders the full app-of-apps
   from that values file and stops on any Helm error. It fails on a revision that is not a SHA or a tag, and says
   whether the render has a `clickhouse-operator` Application; a `clusterScoped: false` environment must have none.
4. **Reconcile the parent.** Merge, then `argocd app get app-of-apps-<env> --refresh` and sync it. It rewrites every
   child from the new render, which replaces the pins from step 1, and prunes children it no longer renders (for a
   stale operator child, see [A stale child Application stays `OutOfSync`](#a-stale-child-application-stays-outofsync)
   first). Turn the parent's self-heal back on.
5. **Then clear stale operations.** Only now `argocd app terminate-op <child>` for a child still running an
   operation from its old spec, or let it complete, and sync it once. Before step 4 it would just retry the old spec.
6. **Remove any one-time option** used during the recovery, such as a `Replace` sync
   ([One-time convergence after switching secret mechanisms](#one-time-convergence-after-switching-secret-mechanisms)),
   and confirm the next sync is server-side apply with no diff.

Record the revision you deployed, the one you rolled back from, and the acceptance report
(`make test/acceptance ENV=<env>`) on the change.

## Operating a standalone ClickHouse

For an environment with `global.clickhouse.standalone: true` (the `standalone` profile; README: [A standalone
ClickHouse](../README.md#a-standalone-clickhouse)). The tenant runs the server: one Deployment named `clickhouse`,
one `clickhouse-data` volume, and no operator to restart, resize or heal anything. With the operator, a
ClickHouseInstallation or an external ClickHouse, the commands below do not apply; the pod there is
`chi-otel-main-0-0-0`, or the service owner's.

> **Rehearsal status.** These procedures are written from the chart (`cluster-nodes/clickhouse/files/standalone/`)
> and the scripts, and **have not been rehearsed**. The standalone kind cluster that would prove them is
> [#259](https://github.com/benhastings/clickhouse-observability-stack/issues/259) (PR #292), still in flight when
> this was written, and the machine this was written on cannot run Docker. [Rehearse before you rely on
> them](#rehearsal-checklist); when you do, replace this note with what you ran, where, and at which revision.

Commands assume `kubectl config set-context --current --namespace=<your namespace>`, and change the cluster
unless they only read.

### Lifecycle

**First install.** Pre-create, in the namespace: the `clickhouse-admin`, `-writer`, `-reader`, `-analyst` and `-garmr`
Secrets (key `password`), the `clickhouse-tls` Secret (`kubernetes.io/tls`) and the CA ConfigMap. On Vault
(`vault.enabled` for `clickhouse` and its clients), write the password fields to the Vault record instead and create
no `clickhouse-<user>` Secret; the server's pod waits in `vault-agent-init` until it can read every one of them, and
stops at start if one is empty. `make cluster/preflight ENV=<env>` checks the Secrets exist, or lists the Vault fields. Then bootstrap. Waves hold everything behind ClickHouse: the `clickhouse` Application
is healthy once the Deployment is Available, and the schema Job (`clickhouse-schema-<hash>`) logs `waiting for
ClickHouse` until the server accepts `otel_admin`, then completes.

```bash
kubectl rollout status deploy/clickhouse --timeout=5m
kubectl get endpoints clickhouse      # ready addresses on 9440 and 8443
kubectl get jobs -l app.kubernetes.io/instance=clickhouse
```

**Restart.** `kubectl rollout restart deploy/clickhouse`. The strategy is `Recreate`, because the volume is
`ReadWriteOnce`: the old pod stops before the new one starts, so ClickHouse is down for the shutdown plus the
start, usually a minute or two. The collector queues and retries, Cerberus and Grafana return errors, and nothing
is lost unless the outage outlasts the collector's queue (`CollectorExportQueueFull` and `CollectorRefusingData`
say so). A single server has no rolling restart; do it in a quiet hour. The startup probe waits for `/ping`; a pod
that is `Running` but not Ready is still loading parts.

**Image upgrade.** Bump `clickhouse.image.tag` and the node's `appVersion` in a PR, as the README's version-bump
rule says, one component per PR. Argo CD syncs it as a restart (above). Before merging, read ClickHouse's release
notes for the jump (changelog entries marked backward incompatible), and take a backup first
([Backup and restore](#backup-and-restore)). Afterwards: the schema Job runs again if the rendered SQL changed,
the pod is Ready, and the [smoke test](#smoke-test-five-minutes) passes. ClickHouse upgrades the on-disk format
as it reads old parts, and newer versions do not always read what an older one wrote, so **rolling back an image
across a minor version is not safe** (see Rollback).

**Failed bootstrap.** Look in this order:

1. The pod is `Pending`: the PVC is unbound (`kubectl describe pvc clickhouse-data`: no StorageClass, or a quota
   on storage), or the namespace quota refuses the pod ([A pod is `Pending`](#a-pod-is-pending)).
2. `ContainerCreating` for long: a missing Secret or ConfigMap it mounts or reads
   (`clickhouse-tls`, `clickhouse-server`, a `clickhouse-<user>` Secret). `describe pod` names it. Create it and the
   pod starts by itself.
3. `CrashLoopBackOff`: `kubectl logs deploy/clickhouse --previous`. A bad certificate or key shows as an OpenSSL
   error at startup; a wrong password variable shows nothing at start but the clients are refused.
4. Running, never Ready: the probe is `/ping` over HTTPS on 8443. The same TLS error from a client
   (`certificate verify failed`) means the certificate does not carry `global.clickhouse.tls.serverName`, or the CA
   bundle is not the one that signed it.
5. Ready, schema Job failing: `kubectl logs job/clickhouse-schema-<hash>`. A failing job is retried and every
   statement is idempotent; fix the cause and delete the failed Job so Argo CD recreates it.

The data volume is not touched by a failed bootstrap. If you delete the Application and start over, the PVC stays
(below) and the new server reads whatever the old one wrote.

**PVC retention.** `clickhouse-data` carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false` and
`helm.sh/resource-policy: keep`. Pruning, deleting the Application and `helm uninstall` all leave it. Two
consequences: reinstalling reuses the data (usually what you want), and **deleting a tenant's stack does not free
its storage or its quota**. To drop the data on purpose: `kubectl delete pvc clickhouse-data` after the pod is gone,
and only after confirming no one needs the telemetry (or a backup is verified). The volume's reclaim policy is the
platform's StorageClass: `Delete` removes the disk with the claim, `Retain` leaves it for the platform team.

**Rollback to the previous revision, without losing telemetry.** The data is on the volume, so it survives any
revert of configuration. Rollback therefore means putting the previous manifests back:

- *Configuration, resources, retention, a bad chart change:* revert the commit (or move `targetRevision` back) and
  let Argo CD sync; the server restarts on the old config over the same data. If the Application is failing
  repeatedly, [pause it](#pausing-a-failing-application) first so the revert is the only thing that syncs. A
  `global.retention` increase back to the old value does not bring back days the TTL already dropped.
- *Image:* safe only within one minor version (patch releases). Across a minor, a downgrade may not be able to read
  parts the newer server wrote or merged, so the supported rollback is: scale to zero, restore the pre-upgrade
  backup into a new volume and point the Deployment at it, accepting the loss since the backup. Decide that at
  upgrade time, not during the incident, which is why the upgrade step takes a backup first.
- *Schema:* statements are idempotent and additive (`ALTER ... IF [NOT] EXISTS`); rolling the chart back does not
  remove what the newer schema added, and the older apps ignore the extra columns and views.

Check the result with the [smoke test](#smoke-test-five-minutes), and compare a count from before and after:
`SELECT count() FROM otel.otel_traces` as `otel_reader` (a count only grows, apart from TTL).

### Rotating credentials and the certificate

The tenant's platform secret system owns the values (Vault, External Secrets or a Kubernetes Secret); the stack
reads them. Rotate one at a time, and confirm the [smoke test](#smoke-test-five-minutes) between them.

**A database password** (`clickhouse-writer`, `-reader`, `-garmr`, `-analyst`, `-admin`):

| Secret | Who changes it | Restart after |
| --- | --- | --- |
| `clickhouse-writer` | the secret owner | `clickhouse`, then `otel-collector` |
| `clickhouse-reader` | the secret owner | `clickhouse`, then `cerberus` and `garmr-sql-adapter` |
| `clickhouse-garmr` | the secret owner | `clickhouse`, then `garmr` |
| `clickhouse-analyst` | the secret owner | `clickhouse` (notebooks and jobs reconnect with the new value) |
| `clickhouse-admin` | the secret owner | `clickhouse`; the next schema Job and backup read the new value |

1. Write the new value in the secret system. A Kubernetes Secret does not roll pods by itself (unless
   `deployment.reloader: true` and Reloader runs); a Vault record never does.
2. Roll the server so it reads the new password: `make cluster/restart APP=clickhouse`. The server reads each
   user's password from an environment variable at start, so **it does not reload a password by itself**.
3. Roll the app that uses it (the table): `make cluster/restart APP=otel-collector`, and so on.

**Overlap.** There is none: a ClickHouse user has one password in this configuration, so between step 2 and step 3
that app is refused. Keep the window short by doing step 3 immediately. The collector queues meanwhile; readers
(Cerberus, garmr sql-adapter) answer errors for that minute. A zero-downtime rotation would need two users per role,
which the stack does not define.

**Back out.** Put the old value back in the secret system and repeat steps 2 and 3. Keep the old value until the
smoke test passes on the new one.

**The server certificate** (`clickhouse-tls`, a `kubernetes.io/tls` Secret from the platform):

- The platform issues it and writes the Secret; the stack never does. It must still carry
  `global.clickhouse.tls.serverName` (the Service's short name `clickhouse`).
- The Secret is mounted as a directory (no `subPath`), so the kubelet refreshes the files within about a minute of
  the Secret changing. ClickHouse re-reads the certificate files when they change, without a restart, per its
  documentation; **confirm that on your version** rather than assuming:

  ```bash
  kubectl port-forward svc/clickhouse 9440:9440 &
  openssl s_client -connect localhost:9440 -servername clickhouse </dev/null 2>/dev/null | openssl x509 -noout -serial -enddate
  ```

  If the old serial is still served after two minutes, `kubectl rollout restart deploy/clickhouse`.
- A new certificate from the **same CA** needs nothing on the clients: they verify against the CA bundle
  (`platform-ca-bundle`), not the leaf. A **new CA** is an overlap problem: put both CAs in the bundle
  (`ca.crt` may hold several PEM certificates) and wait for clients to pick it up (`make cluster/restart` for each of
  `otel-collector`, `cerberus`, `garmr-sql-adapter`, `garmr`, plus a new schema Job), then rotate the server
  certificate, then remove the old CA. Doing it in the other order refuses every client.
- Back out: restore the previous Secret value (and the previous bundle); same checks.
- **With `global.clickhouse.tls.vault`** the certificate, key and CA bundle are Vault fields, written once by the
  Vault agent before each pod starts (pre-populate only), so nothing refreshes them: write the new values in Vault,
  then `make cluster/restart APP=clickhouse` for the certificate, and restart each client (and let a new schema Job
  run) for the CA. The order for a new CA is the same: both CAs in the bundle field and every client restarted
  first, then the certificate, then the old CA out.

**What ClickHouse reloads by itself.** Its `config.d` and `users.d` files from the `clickhouse-server` ConfigMap
are re-read when they change, but the pod's Deployment carries a `checksum/config` annotation, so a ConfigMap
change rolls the pod anyway. The certificate files (above) are the one thing worth relying on without a restart.
Passwords are not reloaded.

### Pausing a failing Application

When one child keeps failing to sync (a bad value, an image that will not pull), stop Argo CD retrying it without
touching the parent `app-of-apps-<env>` or any other child. The parent has self-heal on and would put auto-sync back
if you edited the child's manifest in Git, so pause through the Application object:

```bash
app=clickhouse-<env>          # argocd app list shows the exact name
argocd app set "$app" --sync-policy none     # 1. turn off auto-sync for this child only
argocd app terminate-op "$app"               # 2. stop the operation in flight
argocd app get "$app" --refresh              # 3. re-read Git and the live state
argocd app rollback "$app" <ID>              # 4. optionally, to a previous deployed revision (argocd app history "$app")
```

Without the `argocd` CLI, `kubectl -n argocd patch application "$app" --type merge -p '{"spec":{"syncPolicy":null}}'`
removes auto-sync, `kubectl -n argocd patch application "$app" --type merge -p '{"operation":null}'` clears a running
operation, and annotating it `argocd.argoproj.io/refresh=hard` refreshes it. Rollback needs the CLI or the UI, and
**does not work while auto-sync is on**, which is why it comes after step 1. This changes the cluster.

Two warnings. The parent `app-of-apps-<env>` has self-heal on and owns each child Application, so it can **put the
child's auto-sync back** as drift from Git, within minutes. Check with `argocd app get "$app"` that `Sync Policy` is
still `<none>` before you rely on the pause, and do steps 2 to 4 straight away. If the parent keeps reverting it,
the pause needs the parent's self-heal off for the duration (`argocd app set app-of-apps-<env> --self-heal=false`),
which does touch the parent: say so on the incident, and turn it back on after the fix merges. The pause is
short-lived by design: stop the loop, roll back, fix Git. The clickhouse Application's volume is protected from
prune, so pausing or rolling it back never removes data. **Whether the parent reverts the pause has not been
observed**; it is on the rehearsal checklist.

### Sizing and retention

The README's [Disk sizing](../README.md#disk-sizing) has the formula and the measured bytes per row; `make
measure/disk` measures them on your running server, read-only. For the standalone profile:

- **Storage** is `clickhouse.storage` on `clickhouse-data`: (spans/s × 88 B × days of traces + logs/s × 89 B × days
  of logs + samples/s × 39 B × days of metrics) × 86400 × **1.5 merge headroom**, plus a few hundred megabytes of
  13-month rollups. The 1.5 is not slack to trim: merges need room for old and new parts at once. The figures were
  measured on the demo load only; take your own from `make measure/disk` after a few real days.
- **Retention** is one setting, `global.retention` (`traces`, `logs`, `metrics` in days; `curatedMetrics` for the
  13-month rollups). ClickHouse's TTLs and Cerberus's lookback both follow it, so never set it anywhere else. A
  shorter retention frees space as the TTL merges run, within about a day; a longer one only helps from then on.
- **Growing the volume.** Raise `clickhouse.storage` in the environment file. It grows in place only if the
  StorageClass allows expansion (`kubectl get storageclass <name> -o jsonpath='{.allowVolumeExpansion}'`), and some
  drivers finish after a pod restart. A volume cannot shrink: to go smaller, restore a backup into a smaller new one.
  The tenant's storage quota must hold the new size, or the claim stays `Pending`.
- **Disk-full alerts.** `ClickHouseDiskFilling` (warning, above 80% for 15 minutes) and `ClickHouseDiskFull`
  (critical, above 90% for 5) read `system.disks`, so they work on any volume type, standalone included. A full
  disk stops inserts; the collector queues, then drops. Both ride the stack's own Alertmanager, which is on the same
  cluster, so also give the platform a volume-usage alert on `clickhouse-data` if it can send one somewhere
  independent. Act at the warning: lower retention (quickest) or grow the volume. The [Disk filling
  up](#disk-filling-up) steps apply, with the pod name `deploy/clickhouse` instead of `chi-otel-main-0-0-0`.

### Backup and restore

Owned by the tenant, because there is no service owner behind a standalone server and the platform backs up
volumes only if it says so. Two routes:

- **`clickhouse.backup`** renders a CronJob running clickhouse-backup as `otel_admin` over the verified TLS
  connection (README: [A standalone ClickHouse](../README.md#a-standalone-clickhouse)), to an object store whose
  credentials are the `clickhouse-backup` Secret (`access_key`, `secret_key`). Check that the CronJob's last Job
  succeeded in the [daily check](#daily-check-two-minutes), and **restore it once** into a scratch ClickHouse before
  you need it; an untested backup is not a backup.
- **Volume snapshots** from the platform, if it offers them: ask for the schedule and the restore procedure in
  writing. A snapshot of a running ClickHouse is crash-consistent, which ClickHouse recovers from; prefer to
  snapshot after a quiet minute.

Restore is the platform's or tenant's, not Argo CD's: scale the Deployment to zero, restore into the volume (or a
new PVC and point the Deployment at it), scale up, run the smoke test. Record who is on call for it in the go/no-go
checklist.

### One-time convergence after switching secret mechanisms

An environment that moves a workload from Kubernetes Secrets to Vault (or External Secrets) can leave Argo CD
`OutOfSync` with the container still carrying a `secretKeyRef` env var next to the Vault file. Server-side apply only
removes the fields the same field manager owned, and the earlier apply owned the old ones in another manager's
name, so the stale `env[].valueFrom.secretKeyRef` stays on the live Deployment and the pod keeps reading the old
Secret.

Clear it once, for the one workload, without leaving `Replace=true` on it:

1. Confirm the diff is only that: `argocd app diff <app>` shows `env` entries with `secretKeyRef` removed.
2. Sync that one Application with replacement for this sync only, not in its spec:

   ```bash
   argocd app sync <app> --replace --resource apps:Deployment:<namespace>/<deployment>
   ```

   `--replace` makes Argo CD replace the live object with the rendered one (the Deployment restarts, and with
   `Recreate` or a single replica that is a brief outage).
3. Check `kubectl get deploy <deployment> -o yaml | grep -c secretKeyRef` is `0` for the removed secrets, and the
   Application is Synced.

**Do not** add `Replace=true` to the node's or the Application's `syncOptions` to get this done: it stays on, and
the next sync replaces the object each time (for Grafana it also recreates a Deployment whose data is an
`emptyDir`). If `Replace=true` has already been left on Grafana, remove it with
`argocd app set grafana --sync-option Replace=false` (or edit the Application's `syncOptions`), then sync once.
That is a change to the cluster, applied by hand because Git does not set it. The alternative that touches no sync
option: `kubectl delete deployment <deployment>` and let Argo CD recreate it; pods rebuild from the rendered
manifest, no stale fields.

### Rehearsal checklist

What to run on the standalone kind cluster ([#259](https://github.com/benhastings/clickhouse-observability-stack/issues/259))
to turn the procedures above into rehearsed ones. Record the date, revision and result of each next to it.

- [ ] First install from nothing; the schema Job completes; the smoke test passes.
- [ ] `rollout restart deploy/clickhouse`: observe the outage length and that no telemetry is missing afterwards.
- [ ] Patch image bump, then revert the commit: telemetry count before and after.
- [ ] Delete the Application; confirm `clickhouse-data` remains; reinstall; confirm the data is back.
- [ ] Rotate `clickhouse-writer` and `clickhouse-reader` with `make cluster/restart`; time the refusal window.
- [ ] Replace the `clickhouse-tls` Secret; confirm whether the new serial is served without a restart.
- [ ] Pause a child with a deliberately bad value, terminate, refresh and roll back; confirm the parent and other
  children are untouched, and whether the parent re-enables auto-sync.
- [ ] Take a `clickhouse.backup` (or volume) backup and restore it into a scratch server.
- [ ] Reproduce a stale `secretKeyRef` and clear it with `--replace`.

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
