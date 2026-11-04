# Tenant acceptance contract

What a tenant gets when the stack runs in one namespace with nothing cluster-scoped: the `restricted` profile, or
`paas` when a service owner supplies ClickHouse. It is the agreement to read before signing off an environment, and
it pairs with the [go/no-go checklist](go-no-go.md), which turns it into evidence.

The mechanism is `rbac.scope: namespace` on the collector
([Collector RBAC](../README.md#collector-rbac-cluster-wide-or-one-namespace)). This page says what that means for
the people who use the result.

## Signals

| Signal | Delivered? | Notes |
| --- | --- | --- |
| Traces, logs and metrics sent by OTLP (`:4317`, `:4318`) | Yes | Same pipeline as cluster-wide: batching, export to ClickHouse, readable through Cerberus. |
| Span metrics and service-graph metrics | Yes | Produced by the collector's connectors from the traces it receives; no cluster access needed. |
| Pod attributes on OTLP data (`k8s.pod.name`, `k8s.deployment.name`, ...) | Release namespace only | A sender elsewhere keeps only the attributes it sets itself. |
| Pod phase, container restarts, requests and limits, workload replicas, HPAs, jobs, quotas | Release namespace only | From `k8s_cluster`, through a namespaced Role. |
| Kubernetes events as logs (`kubernetes-events`) | Release namespace only | No node events, no events from other namespaces. |
| Node and pod CPU, memory, filesystem, network, volume usage (`kubeletstats`) | **No** | The kubelet's `nodes/stats` is cluster-scoped; no Role grants it. The render fails if the agent DaemonSet is also enabled. |
| Node conditions and allocatable, namespace phase | **No** | Cluster-scoped objects. |
| The stack's own telemetry: collector, ClickHouse, Cerberus, garmr, Alertmanager | Yes | Scraped inside the namespace. |
| Alertmanager notification history | Yes | Written as logs, as before. |

A tenant that needs the missing signals asks the platform team for them from its own cluster monitoring; this
bundle can't supply them from inside a namespace.

## Dashboards

| Dashboard | Cluster-scoped installs | Tenant namespace |
| --- | --- | --- |
| Span metrics | Full | Full, except the Resources row: CPU and memory usage panels are empty; requests, limits and restarts remain for the release namespace. The Kubernetes events annotation shows release-namespace events only. |
| SLOs | Full | Full: computed from server spans in ClickHouse. |
| Alert hygiene | Full | Full: reads Alertmanager's history logs. |
| Stack health | Full | Full, except panels that read the collector's CPU or memory from `kubeletstats`. |
| Kubernetes | Full | Mostly empty: no Nodes row, Top memory, Top CPU, memory by namespace or usage against requests. Pod phase, restarts and workloads show for the release namespace. |

## Alerts

| Alert | Tenant namespace |
| --- | --- |
| `CollectorMemoryNearLimit` | **Never fires.** It reads the collector's working set from `kubeletstats`. Memory pressure still shows as `CollectorMemoryLimiterRefusing` and `CollectorRefusingData`, which read the collector's own telemetry. |
| `AvailabilityBudgetBurn`, `LatencyBudgetBurn` | Work: they read spans. |
| `RequestRateAnomaly`, `ErrorRatioAnomaly`, `LatencyAnomaly`, `ErrorLogAnomaly`, `TelemetryAbsent` | Work: they read ClickHouse baselines. |
| `CollectorExportFailing`, `CollectorExportQueueFull`, `ClickHouse*`, `BaselineRefreshFailing`, `AlertmanagerNotificationsFailing`, `SpanMetricsCardinalityLimitHit`, `Watchdog` | Work: they read the stack's own scrapes. |

An alert that never fires is the dangerous kind, so an environment that relies on `CollectorMemoryNearLimit` records
a replacement in its go/no-go checklist (gate 5) before it goes live: a platform alert on the collector pod's
memory.

## Proving it in the environment

`make test/acceptance ENV=<env>` ([README](../README.md#proving-an-environment-in-place)) checks a running
namespace against gates 2, 3, 4 and 5 and writes the report the [checklist](go-no-go.md) asks for. Give it a
Grafana login (`GRAFANA_TOKEN` or `GRAFANA_AUTH`); it reads no Secret. With the CA bundle in Vault
(`global.clickhouse.tls.vault`), give it the bundle as `CA_FILE`; otherwise it reads the CA ConfigMap. Set
`SECRET_OWNER` (who delivers the credentials) and `ROLLBACK_REVISION` (the revision to go back to) to record them in
the report, which also says how each workload gets its credentials. `make check/live ENV=<env>` covers gate 6.

| Check | Gate |
| --- | --- |
| Argo CD: every Application of the environment is Synced and Healthy | 5 |
| Workloads: every Deployment and StatefulSet is ready; no Job has failed | 2, 5 |
| ClickHouse: ready; its Service has ready endpoints; the schema Job completed | 2 |
| ClickHouse: its Service serves no plaintext port | 4 |
| ClickHouse (standalone): its certificate verifies by `serverName` against the platform's CA, and not by `clickhouse.<ns>.svc.cluster.local` | 4 |
| Secrets: no pod waits on a missing Secret | 1 |
| Vault: no pod is stuck in `vault-agent-init`, or with its `vault-agent` in `CrashLoopBackOff` | 1 |
| Quota: no pod creation is refused by the quota or admission | 5 |
| OTLP, Cerberus and Grafana: a synthetic trace, log and metric are accepted and read back | 3 |

With `paas`, ClickHouse is the service owner's, so its readiness, endpoints and ports are `SKIP`; the schema Job and
the round trip still prove the stack reaches it. A `restricted` install serves ClickHouse's plaintext ports, so it
fails gate 4 by design: only `standalone` and `paas` are TLS only.

### What a broken namespace reports

`make test/acceptance-stub` runs the test against a stand-in for a broken `standalone` namespace and requires
exactly these failures. A real environment broken the same way reports the same lines, each naming the object:

| What is broken | Checks that fail |
| --- | --- |
| A Secret ClickHouse reads (`clickhouse-admin`) is missing, so its pod waits in `CreateContainerConfigError` | Secrets (names the pod and the Secret); Workloads; ClickHouse ready; endpoints; the schema Job, which can't finish; the Argo CD Application, Degraded |
| A pod's Vault agent can't read its records (role, policy, path, or no route to Vault), so it waits in `vault-agent-init` | Vault (names the pod); Workloads |
| The server's certificate doesn't verify against the CA by `serverName` (wrong CA, expired, wrong name) | ClickHouse: the certificate check. A certificate that also verifies by the cluster-local name fails the other one |
| The namespace quota refuses a ReplicaSet's or an unfinished Job's pods | Quota (names the object and the quota's message); Workloads |
| The collector accepts OTLP but nothing reaches ClickHouse, or Cerberus can't read it | Cerberus: the trace, the log and the metric; Grafana: the same three |
| No `GRAFANA_TOKEN` or `GRAFANA_AUTH` given | Grafana: all three |
| The collector refuses OTLP, or no endpoint answers | OTLP; then every read-back check, since nothing was sent |

A refusal or a `FailedMount` that has since cleared doesn't fail the run: the Quota check counts a `FailedCreate`
event only from the last 15 minutes (`ACCEPTANCE_EVENT_WINDOW`) and only for a Job still unfinished or a StatefulSet
still short of ready pods, and the Secrets check only pods still waiting.

## What a tenant accepts

- No kubelet, node or cross-namespace Kubernetes signals, as above.
- The shared pieces (operator, CRDs, Gateway, namespace labels) belong to the platform team, not this bundle.
- With `paas`, ClickHouse availability, backups and its certificate belong to the service owner. The stack's side is
  the verified TLS connection and the schema Job ([An external ClickHouse](../README.md#an-external-clickhouse)).

Accepting the contract is gate 6 of the [checklist](go-no-go.md#6-revision-set): the owner records it with the
revision.
