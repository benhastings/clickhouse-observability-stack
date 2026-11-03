# Tenant acceptance contract

What a tenant gets when the stack runs in one namespace with nothing cluster-scoped: the `restricted` profile, or
`paas` when a service owner supplies ClickHouse. It is the agreement to read before signing off an environment, and
it pairs with the [go/no-go checklist](go-no-go.md), which turns it into evidence.

The mechanism is `rbac.scope: namespace` on the collector
([Collector RBAC](../README.md#collector-rbac-cluster-wide-or-one-namespace)). This page says what that means for
the people who use the result.

> `make test/acceptance` (in-environment proof, #260) and `make check/live` (revision drift, #262) are planned and
> not in the repository yet. Where this page names them, run the manual step beside them until they land.

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

## What a tenant accepts

- No kubelet, node or cross-namespace Kubernetes signals, as above.
- The shared pieces (operator, CRDs, Gateway, namespace labels) belong to the platform team, not this bundle.
- With `paas`, ClickHouse availability, backups and its certificate belong to the service owner. The stack's side is
  the verified TLS connection and the schema Job ([An external ClickHouse](../README.md#an-external-clickhouse)).

Accepting the contract is gate 6 of the [checklist](go-no-go.md#6-revision-set): the owner records it with the
revision.
