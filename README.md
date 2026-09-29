# ClickHouse observability stack (Argo CD app-of-apps)

A GitOps deployment of an OpenTelemetry pipeline that stores **traces, logs and metrics in ClickHouse** and lets **Grafana query them with PromQL, LogQL and TraceQL**. Grafana doesn't talk to ClickHouse directly: Cerberus sits in between and speaks the Prometheus, Loki and Tempo APIs on ClickHouse's behalf.

One Argo CD "root" Application deploys everything else. It's sized for a laptop and verified end to end on a local kind cluster.

```mermaid
flowchart LR
    APP[Apps / demo-load] -- OTLP --> COL[OTel Collector<br/>contrib]
    COL -- traces --> SM[spanmetrics +<br/>servicegraph connectors]
    SM -- metrics --> COL
    COL -- traces, logs, metrics --> CH[(ClickHouse<br/>Altinity operator)]
    CER[Cerberus] -- SQL --> CH
    GF[Grafana] -- PromQL / LogQL / TraceQL --> CER
```

## Components

| App | Chart | Version | What it does |
|---|---|---|---|
| `clickhouse-operator` | [altinity/altinity-clickhouse-operator](https://github.com/Altinity/clickhouse-operator) | chart 0.27.4 | Runs ClickHouse from a `ClickHouseInstallation` resource. |
| `clickhouse` | (plain manifests) | ClickHouse server 26.9.5.2 | Single-node ClickHouse, tuned for low memory. |
| `cerberus` | [tsouza/cerberus](https://github.com/tsouza/cerberus) (OCI) | chart 0.18.0, app 1.22.0 | Prometheus, Loki and Tempo HTTP APIs over ClickHouse. Also creates the OTel tables. |
| `otel-collector` | [open-telemetry/opentelemetry-collector](https://github.com/open-telemetry/opentelemetry-helm-charts) | chart 0.173.1, contrib image 0.161.0 | Receives OTLP, derives span metrics and service-graph metrics, and writes to ClickHouse. |
| `grafana` | [grafana-community/grafana](https://github.com/grafana-community/helm-charts) | chart 13.2.6, Grafana 13.2.2 | Three datasources that all point at Cerberus, plus a span-metrics dashboard. |
| `demo-load` | (plain manifests) | telemetrygen v0.161.0 | Optional synthetic traces and logs. |

Argo CD itself is installed by `scripts/kind-up.sh` (chart `argo/argo-cd` 10.9.2, Argo CD v3.5.3).

## Quick start (local kind cluster)

**Requirements:**
- Docker, with your user able to use it
- `kind`, `kubectl` and `helm`, for example `mise use -g kind kubectl helm`
- About 3 GB of free RAM. The whole cluster used about 2.4 GB in testing.

```bash
scripts/kind-up.sh                         # cluster + Argo CD + root app (~10 min on first run)
kubectl -n argocd get applications -w      # wait for all 7 apps: Synced / Healthy
scripts/port-forward.sh                    # prints URLs and logins
```

| URL | What |
|---|---|
| http://localhost:3000 | Grafana (`admin` / `admin`). Open **Dashboards → Cerberus → Span metrics (RED)**. |
| http://localhost:8080 | Argo CD (`admin` / the password printed by the script) |
| http://localhost:8081 | Cerberus APIs, for curl |
| `localhost:4317` / `http://localhost:4318` | OTLP gRPC / HTTP into the collector |

Tear down with `scripts/kind-down.sh`.

### What you should see

With the default demo load:

| service | requests/s | error rate | p95 latency |
|---|---|---|---|
| `checkout` | 2 | 0% | under 100 ms |
| `payments` | 4 | ~25% | ~900 ms |

- **Explore → Tempo (Cerberus):** TraceQL such as `{resource.service.name="payments" && status=error}` finds the failing traces. The Service Graph tab uses the servicegraph metrics.
- **Explore → Loki (Cerberus):** `{service_name="checkout"}` shows the demo log lines.

### Sending your own telemetry

With `scripts/port-forward.sh` running, point any OTLP exporter at `localhost:4317` (gRPC) or `http://localhost:4318` (HTTP). For example:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_SERVICE_NAME=my-app ./my-app
```

Inside the cluster, use `otel-collector.observability:4317`.

To stop the demo load, delete `apps/demo-load.yaml` and push. The root app prunes it.

## Design decisions

### Span metrics: the collector's `spanmetrics` connector, not a ClickHouse materialized view

Both were considered. The connector was chosen because:

- **It counts before sampling.** The connector sees every span as it passes through the collector. A materialized view only sees spans that were actually stored, so any trace sampling would make request and error counts wrong.
- **Its output works in Grafana as-is.** It produces standard counter and histogram series, with trace-ID exemplars. Those are exactly what PromQL `rate()` and `histogram_quantile()`, and therefore Grafana's RED dashboards, expect through Cerberus.
- **A view is a poor fit here.** A ClickHouse view fires once per insert batch, so it would produce fragmented delta rows rather than proper time series. It would also have to reproduce the exporter's histogram layout exactly, and that layout has changed between exporter versions.

**The trade-off:** the connector keeps counters in memory. With more than one collector replica, each replica produces its own series (distinguished by a `collector_instance_id` label), and a restart starts the counters over. PromQL `rate()` handles both. If you scale out, route spans to collectors by trace ID with the `loadbalancing` exporter.

The `servicegraph` connector was also added, because Grafana's Tempo "Service Graph" view expects its metrics.

Resulting metric names, as queried through Cerberus:

- `traces_span_metrics_calls` — counter, labelled `service_name`, `span_name`, `span_kind`, `status_code`, plus `http_*` dimensions
- `traces_span_metrics_duration_bucket` / `_sum` / `_count` — histogram in milliseconds
- `traces_service_graph_request_total`, `traces_service_graph_request_failed_total`, and related metrics

### Cerberus creates the tables, not the collector

Cerberus is validated against the ClickHouse exporter's **v0.152** table layout. The latest exporter (v0.161) changed some column types; for example, metrics `TimeUnix` went from `DateTime64(9)` to `DateTime`. So:

- Cerberus runs with `autoCreate.schema: true` and creates the database and tables in the layout it expects.
- The collector's exporter runs with `create_schema: false` and inserts into those tables.

This combination was tested: exporter v0.161 inserts into the v0.152 layout without errors, and Cerberus answers PromQL, LogQL and TraceQL correctly over the result.

### Sync order

Child apps carry sync waves:

| wave | app |
|---|---|
| 0 | operator |
| 1 | ClickHouse |
| 2 | Cerberus |
| 3 | collector, Grafana |
| 4 | demo-load |

Argo CD doesn't track child-app health by default, so `bootstrap/argocd-values.yaml` adds two health checks:
- one that treats a child Application as healthy only when it's synced *and* healthy
- one that treats the ClickHouse installation as healthy only once the operator reports it `Completed`

On the very first install, expect a few minutes of retry noise. The collector logs DNS and "database does not exist" errors, and Cerberus reports not-ready, until ClickHouse is up and Cerberus has created the tables. Both recover on their own.

### Low-memory sizing

Everything is sized for light local testing:

| component | memory request | memory cap |
|---|---|---|
| ClickHouse | 256 Mi | 1 Gi |
| Grafana | 96 Mi | 384 Mi |
| Cerberus | 64 Mi | 384 Mi |
| Collector | 64 Mi | 256 Mi |
| Operator | 48 Mi | 192 Mi |

ClickHouse also gets a `config.d/low_memory.xml` (in `manifests/clickhouse/clickhouseinstallation.yaml`) with:
- small caches
- fewer background threads
- its internal system log tables (query log, metric log, trace log and so on) turned off

`background_pool_size` is left at its default on purpose: ClickHouse refuses to create tables if it's lower than its merge and mutation thresholds.

## Repository layout

```
bootstrap/
  argocd-values.yaml       Argo CD Helm values: small footprint, health checks for waves
  repositories.yaml        Registers Cerberus's OCI Helm registry with Argo CD
  root-app.yaml            The app-of-apps: deploys everything in apps/
apps/                      One Argo CD Application per component (with sync waves)
values/                    Helm values for each chart
manifests/
  clickhouse/              ClickHouseInstallation + credentials Secret
  grafana-dashboards/      Span-metrics dashboard (loaded by Grafana's sidecar)
  demo-load/               telemetrygen Deployment
scripts/                   kind-up / port-forward / kind-down
kind-config.yaml           Local cluster definition
```

Chart-based apps use Argo CD multi-source Applications. The chart comes from its Helm repo and the values file from this repo (`$values/values/<app>.yaml`).

## Troubleshooting

These problems all came up while building this, and the fixes are already in the repo.

- **`kind create cluster` fails at "Starting control-plane" (API server connection refused):**
  - Hosts with a **btrfs root on an encrypted (`/dev/mapper`) volume** need `/dev/mapper` mounted into the kind node, or the kubelet never starts the control plane.
  - Slow container creation on such hosts also needs longer kubeadm timeouts.
  - `kind-config.yaml` handles both.
- **ClickHouse pod never appears:**
  - The Altinity operator only watches its own namespace by default. `values/clickhouse-operator.yaml` sets `watchNamespaces: [observability]`.
  - Check `kubectl -n observability get chi otel -o jsonpath='{.status.status} {.status.errors}'`.
- **Installation `Aborted` with `RemovedSecretRefSyntax`:** operator 0.27.4 removed `user/k8s_secret_password`. Use `user/password: {valueFrom: {secretKeyRef: ...}}` instead, as this repo does.
- **Cerberus stays `0/1 Ready`:** it reports not-ready until it has created the schema. Check `kubectl -n observability logs deploy/cerberus`.
- **A Loki API call returns `missing or invalid 'end' parameter`:** Cerberus requires both `start` and `end` on `query_range`. Grafana always sends both; this only affects hand-written curl calls.
- **Querying ClickHouse directly:**
  ```bash
  kubectl -n observability exec -it chi-otel-main-0-0-0 -c clickhouse -- \
    clickhouse-client --user otel --password otel-local-dev
  ```

## Before using this beyond a laptop

- **Credentials:** `manifests/clickhouse/credentials.yaml` and the Grafana `admin`/`admin` login are **public, local-only credentials**. Replace them with a secret manager (for example External Secrets or Sealed Secrets).
- **ClickHouse sizing:** raise the memory settings, and remove or relax the low-memory config.
- **Collector scaling:** use trace-ID-aware load balancing so span metrics stay consistent across replicas.
- **Retention:** set it with `schema.ttl` in `values/cerberus.yaml` (currently `7d`). Also set `CERBERUS_PROM_METADATA_LOOKBACK` if retention exceeds 14 days.
- **Cerberus maturity:** it's a young project (1.x, moving fast). Pin versions and test upgrades.
