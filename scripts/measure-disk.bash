#!/usr/bin/env bash
# Measures the README's Disk sizing inputs on a running stack (make measure/disk): compressed bytes per row for
# each signal, the ingest rates over WINDOW_HOURS, and the peak disk use over the same window against the bytes
# the active parts hold, which is the formula's 1.5 headroom. Read-only. Run it after the stack has run for at
# least a few days; the figures from a shorter run are not steady state.
#   NAMESPACE (observability)  CLICKHOUSE_POD (the first pod labelled app.kubernetes.io/name=clickhouse)
#   WINDOW_HOURS (72)          ADMIN_SECRET (clickhouse-admin, user otel_admin)
set -euo pipefail

ns="${NAMESPACE:-observability}"
hours="${WINDOW_HOURS:-72}"
secret="${ADMIN_SECRET:-clickhouse-admin}"
pod="${CLICKHOUSE_POD:-$(kubectl -n "$ns" get pods -l app.kubernetes.io/name=clickhouse -o name | head -1)}"
[[ -n "$pod" ]] || { echo "no ClickHouse pod in namespace $ns; set CLICKHOUSE_POD" >&2; exit 1; }
password="$(kubectl -n "$ns" get secret "$secret" -o go-template='{{.data.password | base64decode}}')"

sql() {
  kubectl -n "$ns" exec -i "$pod" -c clickhouse -- \
    clickhouse-client --user otel_admin --password "$password" --format PrettyCompactMonoBlock --query "$1"
}
scalar() {
  kubectl -n "$ns" exec -i "$pod" -c clickhouse -- \
    clickhouse-client --user otel_admin --password "$password" --query "$1"
}

echo "== bytes per row (active parts, indexes included) =="
sql "SELECT table, sum(rows) AS row_count, formatReadableSize(sum(bytes_on_disk)) AS on_disk,
  round(sum(bytes_on_disk) / sum(rows), 1) AS bytes_per_row
FROM system.parts WHERE active AND database = 'otel' GROUP BY table ORDER BY sum(bytes_on_disk) DESC"

echo "== rows per second over the last ${hours}h =="
sql "SELECT 'spans' AS signal, round(count() / ${hours}/3600, 2) AS per_second FROM otel.otel_traces
  WHERE Timestamp > now() - INTERVAL ${hours} HOUR
UNION ALL SELECT 'logs', round(count() / ${hours}/3600, 2) FROM otel.otel_logs
  WHERE Timestamp > now() - INTERVAL ${hours} HOUR
UNION ALL SELECT 'metric samples', round((
    (SELECT count() FROM otel.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL ${hours} HOUR) +
    (SELECT count() FROM otel.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL ${hours} HOUR) +
    (SELECT count() FROM otel.otel_metrics_histogram WHERE TimeUnix > now() - INTERVAL ${hours} HOUR)
  ) / ${hours}/3600, 2)"

echo "== blended bytes per metric sample =="
scalar "SELECT round(sum(bytes_on_disk) / sum(rows), 1) FROM system.parts
  WHERE active AND database = 'otel' AND startsWith(table, 'otel_metrics_')"

echo "== disk use: peak over the last ${hours}h against the active parts =="
sql "SELECT formatReadableSize(max(value)) AS peak_used,
  formatReadableSize((SELECT sum(bytes_on_disk) FROM system.parts WHERE active)) AS active_parts,
  round(max(value) / (SELECT sum(bytes_on_disk) FROM system.parts WHERE active), 2) AS headroom
FROM system.asynchronous_metric_log
WHERE metric = 'DiskUsed_default' AND event_time > now() - INTERVAL ${hours} HOUR"
echo "Peak is the highest sample of DiskUsed_default; system.asynchronous_metric_log samples once a minute."
echo "Put the bytes per row and headroom in the README's Disk sizing table with this workload's description."
