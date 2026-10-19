# Analysing the telemetry

Everything the stack stores is in ClickHouse, so a notebook or a job can read it with SQL as `otel_analyst`
(see the README's **The schema and the ClickHouse users** for its limits and grants). This page lists what is where, then walks through
reading it from Python and writing a model's scores back as series Grafana and vmalert can use.

## Data dictionary

| table | a row is | columns that matter |
|---|---|---|
| `otel.otel_traces` | one span | `Timestamp`, `TraceId`, `SpanId`, `ParentSpanId` (empty for a root span), `ServiceName`, `SpanName`, `SpanKind` (`Server`, `Client`, `Internal`, …), `Duration` (ns), `StatusCode` (`Error`, `Ok`, `Unset`), `SpanAttributes`, `ResourceAttributes`, `Events.*`, `Links.*` |
| `otel.otel_logs` | one log record | `Timestamp`, `ServiceName`, `SeverityText`, `SeverityNumber` (17 and up is ERROR), `Body`, `TraceId`, `SpanId`, `LogAttributes`, `ResourceAttributes` |
| `otel.otel_metrics_sum` | one sample of a counter or sum | `TimeUnix`, `MetricName`, `ServiceName`, `Value` (cumulative for counters), `Attributes`, `ResourceAttributes` |
| `otel.otel_metrics_gauge` | one sample of a gauge | `TimeUnix`, `MetricName`, `ServiceName`, `Value`, `Attributes`, `ResourceAttributes`; also the `baseline:*`, `slo:*` and `ml:*` series ClickHouse writes back |
| `otel.otel_metrics_histogram` | one sample of a histogram | `TimeUnix`, `MetricName`, `ServiceName`, `Count`, `Sum`, `BucketCounts`, `ExplicitBounds`, `Attributes` |
| `otel_baseline.signal_1m` | one signal of one service in one minute | `Minute`, `ServiceName`, `Signal` (`requests_per_minute`, `error_ratio`, `latency_p95_ms`, `error_logs_per_minute`), `Value` |
| `otel_features.trace_summary` | one trace | `TraceId`, `Start`, `DurationMs`, `RootService`, `RootOperation`, `RootRoute`, `Spans`, `Errors`, `Services` |
| `otel_features.log_templates` | one message template of one service in one minute | `Minute`, `ServiceName`, `SeverityText`, `Template`, `TemplateHash`, `Count`, `Example` |
| `otel_ml.scores` | one score a model wrote | `Time`, `Model`, `ServiceName`, `Signal`, `Value` |

OpenTelemetry attributes land in map columns by where they were set: resource attributes (`service.name`,
`k8s.pod.name`, `deployment.environment.name`) in `ResourceAttributes`, a span's own in `SpanAttributes`, a log
record's in `LogAttributes`, a metric point's in `Attributes`. Read one with `SpanAttributes['http.route']`.
Cerberus shows the same attributes as labels with dots turned into underscores (`k8s_pod_name`). `otel_slo`
(the SLO views) is read by vmalert and Grafana, not by `otel_analyst`.

## Connecting

Forward ClickHouse's HTTP port and put the analyst's password in the environment:

```sh
kubectl -n observability port-forward svc/clickhouse 8123 &
export CLICKHOUSE_PASSWORD="$(kubectl -n observability get secret clickhouse-analyst -o jsonpath='{.data.password}' | base64 -d)"
pip install clickhouse-connect pandas pyarrow
```

```python
import os
import clickhouse_connect

client = clickhouse_connect.get_client(host="localhost", port=8123, username="otel_analyst",
                                       password=os.environ["CLICKHOUSE_PASSWORD"])
print(client.query("SELECT currentUser(), getSetting('max_memory_usage')").result_rows)
```

The snippets below run in that session, in order.

## Recipes

A day of traces into pandas, one row per trace:

```python
traces = client.query_df("""
    SELECT Start, DurationMs, RootService, RootOperation, Spans, Errors, Services
    FROM otel_features.trace_summary
    WHERE Start > now() - INTERVAL 1 DAY
""")
print(len(traces), "traces;", round((traces.Errors > 0).mean(), 3), "with an error")
print(traces.groupby("RootOperation").DurationMs.quantile(0.95))
```

Each service's error log templates over the last hour, most frequent first:

```python
templates = client.query_df("""
    SELECT ServiceName, Template, sum(Count) AS n, any(Example) AS example
    FROM otel_features.log_templates
    WHERE Minute > now() - INTERVAL 1 HOUR AND SeverityText IN ('ERROR', 'FATAL')
    GROUP BY ServiceName, Template
    ORDER BY n DESC
""")
print(templates.head(10).to_string(index=False))
```

The spans of one failing trace, as a tree:

```python
trace_id = client.query("""
    SELECT TraceId FROM otel_features.trace_summary
    WHERE Errors > 0 AND has(Services, 'payments') ORDER BY Start DESC LIMIT 1
""").result_rows[0][0]
spans = client.query_df("""
    SELECT SpanId, ParentSpanId, ServiceName, SpanName, Duration / 1e6 AS ms, StatusCode
    FROM otel.otel_traces
    WHERE TraceId = {trace_id:String} AND Timestamp > now() - INTERVAL 1 DAY
    ORDER BY Timestamp
""", parameters={"trace_id": trace_id})

children = {}
for span in spans.itertuples():
    children.setdefault(span.ParentSpanId, []).append(span)

def show(parent, depth=0):
    for span in children.get(parent, []):
        print(f"{'  ' * depth}{span.ServiceName}: {span.SpanName} {span.ms:.1f} ms {span.StatusCode}")
        show(span.SpanId, depth + 1)

show("")
```

## Export

A table for offline training, as Parquet, without the analyst's limits getting in the way of a large read
(page through days if it hits `max_rows_to_read`):

```python
result = client.raw_query("""
    SELECT * FROM otel_features.trace_summary WHERE Start > now() - INTERVAL 1 DAY
""", fmt="Parquet")
with open("trace_summary.parquet", "wb") as f:
    f.write(result)
```

To write straight to object storage instead, `otel_admin` (or a user granted the `S3` source) can run
`INSERT INTO FUNCTION s3('https://<bucket>.s3.amazonaws.com/trace_summary.parquet', '<key>', '<secret>', 'Parquet')
SELECT ...`; `otel_analyst` has no such grant.

## Write back

A model writes its scores to `otel_ml.scores`. Each row becomes a gauge sample named `ml:<Model>:<Signal>` for
its service (a view in the clickhouse node's schema), so Grafana can draw it and a vmalert rule can alert on
it, as the anomaly baselines do. Here a toy model scores each service's last hour of error ratios against
their mean:

```python
from datetime import datetime, timezone

signals = client.query_df("""
    SELECT Minute, ServiceName, Value FROM otel_baseline.signal_1m FINAL
    WHERE Signal = 'error_ratio' AND Minute > now() - INTERVAL 1 HOUR
""")
stats = signals.groupby("ServiceName").Value.agg(["mean", "std"])
latest = signals.sort_values("Minute").groupby("ServiceName").tail(1).set_index("ServiceName")
z = ((latest.Value - stats["mean"]) / stats["std"].where(stats["std"] > 0)).fillna(0.0)

now = datetime.now(timezone.utc)
rows = [[now, "toy", service, "error_ratio_z", float(score)] for service, score in z.items()]
client.insert("otel_ml.scores", rows, column_names=["Time", "Model", "ServiceName", "Signal", "Value"])
print(rows)
```

Through Cerberus, and in Grafana's Explore, the scores are now `ml:toy:error_ratio_z{service_name="payments"}`.
Give `Time` a timezone-aware datetime, or leave it out for the current time: `clickhouse-connect` reads a naive
datetime as the client's local time, so a notebook outside UTC would write scores hours into the past or future.
