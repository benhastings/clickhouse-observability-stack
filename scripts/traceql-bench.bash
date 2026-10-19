#!/usr/bin/env bash
# Times TraceQL through Cerberus over three weeks of synthetic traces, in a throwaway ClickHouse and Cerberus
# in Docker (make test/traceql-latency). Run by hand; not part of CI. RATE is spans per second (default 50),
# DAYS how far back the traces go (default 21). Prints a table of median and fastest times over three runs,
# with the rows ClickHouse read for each request.
set -euo pipefail
cd "$(dirname "$0")/.."

RATE="${RATE:-50}"
DAYS="${DAYS:-21}"
RUNS=3
prefix="traceql-bench-$$"
net="$prefix"
ch="$prefix-clickhouse"
cerberus="$prefix-cerberus"
port="${PORT:-18089}"
password="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

ch_image="$(yq '.clickhouse.image | .repository + ":" + .tag' cluster-nodes/clickhouse/values.yaml)"
cerberus_image="$(yq '.deployment.containers.cerberus.image | .repository + ":" + .tag' cluster-nodes/cerberus/values.yaml)"

cleanup() { rm -f "${body:-}"; docker rm -f "$ch" "$cerberus" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

sql() { docker exec -i "$ch" clickhouse-client --user bench --password "$password" --multiquery "$@"; }

echo "==> $ch_image and $cerberus_image, $DAYS days at $RATE spans/s"
docker network create "$net" >/dev/null
docker run -d --name "$ch" --network "$net" --ulimit nofile=262144:262144 \
  -e CLICKHOUSE_USER=bench -e CLICKHOUSE_PASSWORD="$password" -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  "$ch_image" >/dev/null
until sql --query "SELECT 1" >/dev/null 2>&1; do sleep 1; done

echo "==> Applying the clickhouse node's schema (baselines and SLOs off, traces kept 30 days)"
# The schema's views run as otel_admin, so that user has to exist.
sql --query "CREATE USER IF NOT EXISTS otel_admin IDENTIFIED WITH no_password HOST LOCAL; GRANT CURRENT GRANTS ON *.* TO otel_admin WITH GRANT OPTION"
helm template bench cluster-nodes/clickhouse \
  --set clickhouse.baselines.enabled=false --set clickhouse.slo.enabled=false \
  --set clickhouse.schema.ttlDays.traces=30 2>/dev/null |
  yq 'select(.kind == "ConfigMap") | .data["schema.sql"]' | sql >/dev/null

# Each trace is three spans: web's click (the root), checkout's server span for one of 20 routes, and payments'
# charge. 5% of traces fail in checkout and payments. Durations are 50 to 950 ms. Today is seeded whole, so
# the last hours are there and the rest of today is in the future.
echo "==> Seeding $DAYS days of traces"
spans_per_day=$((RATE * 86400))
for ((d = DAYS - 1; d >= 0; d--)); do
  sql --query "
    INSERT INTO otel.otel_traces
      (Timestamp, TraceId, SpanId, ParentSpanId, TraceState, SpanName, SpanKind, ServiceName,
       ResourceAttributes, ScopeName, ScopeVersion, SpanAttributes, Duration, StatusCode, StatusMessage)
    WITH toStartOfDay(now()) - toIntervalDay($d) AS day_start,
         $((DAYS - d)) * $spans_per_day + number AS n,
         intDiv(n, 3) AS t,
         n % 3 AS lvl,
         ['/checkout', '/cart', '/cart/items', '/orders', '/orders/{id}', '/payments', '/users/{id}', '/search',
          '/products', '/products/{id}', '/inventory', '/promotions', '/shipping', '/tax', '/login', '/logout',
          '/profile', '/wishlist', '/reviews', '/recommendations'][1 + cityHash64(t, 1) % 20] AS route,
         cityHash64(t, 2) % 100 < 5 AS failed
    SELECT day_start + toIntervalMillisecond(intDiv(intDiv(number, 3) * 3000, $RATE) + lvl * 2),
           lower(hex(MD5(toString(t)))),
           substring(lower(hex(MD5(toString(n)))), 1, 16),
           if(lvl = 0, '', substring(lower(hex(MD5(toString(n - 1)))), 1, 16)),
           '',
           multiIf(lvl = 0, 'click', lvl = 1, 'POST ' || route, 'POST /api/v1/charge'),
           if(lvl = 0, 'Internal', 'Server'),
           ['web', 'checkout', 'payments'][lvl + 1],
           map('service.name', ['web', 'checkout', 'payments'][lvl + 1], 'service.version', 'v1.9.0',
               'deployment.environment.name', 'bench', 'k8s.namespace.name', 'shop',
               'k8s.pod.name', ['web', 'checkout', 'payments'][lvl + 1] || '-' || toString(cityHash64(t, 3) % 4),
               'cloud.region', 'us-east-1', 'telemetry.sdk.language', 'go'),
           'bench', '1.0',
           map('http.route', if(lvl = 1, route, '/api/v1/charge'), 'http.request.method', 'POST',
               'http.response.status_code', if(failed AND lvl > 0, '502', '200')),
           (50 + cityHash64(n, 4) % 900) * 1000000,
           if(failed AND lvl > 0, 'Error', 'Unset'),
           ''
    FROM numbers($spans_per_day)
    SETTINGS max_insert_threads = 4"
  printf '.'
done
echo
sql --query "SELECT sum(rows), formatReadableSize(sum(bytes_on_disk))
             FROM system.parts WHERE active AND database = 'otel' AND table = 'otel_traces' FORMAT TSV" |
  awk -F'\t' '{printf "    %.1f million spans, %s on disk\n", $1 / 1e6, $2}'

echo "==> Starting Cerberus"
docker run -d --name "$cerberus" --network "$net" -p "127.0.0.1:$port:8080" \
  -e CERBERUS_CH_ADDR="$ch:9000" -e CERBERUS_CH_DATABASE=otel -e CERBERUS_CH_USERNAME=bench \
  -e CERBERUS_CH_PASSWORD="$password" -e CERBERUS_CH_PROTOCOL=native -e CERBERUS_CH_OPTIMIZATIONS=auto \
  -e CERBERUS_AUTO_CREATE_SCHEMA=false -e CERBERUS_AUTO_CREATE_DATABASE=false \
  -e CERBERUS_HTTP_ADDR=:8080 -e CERBERUS_LOG_LEVEL=warn "$cerberus_image" >/dev/null
until curl -fsS -G "http://localhost:$port/api/v1/query" --data-urlencode query=1 >/dev/null 2>&1; do sleep 1; done

now="$(date +%s)"
age=$((DAYS > 20 ? 10 : DAYS / 2))
trace_id="$(sql --query "SELECT TraceId FROM otel.otel_traces
  WHERE Timestamp BETWEEN now() - INTERVAL $age DAY AND now() - INTERVAL $age DAY + INTERVAL 1 MINUTE
    AND ParentSpanId = '' LIMIT 1")"

# bench <label> <curl args...>: RUNS timed requests; the rows read are summed over the queries ClickHouse ran for
# the last one, and found is how many traces (or series) it returned.
results=()
body="$(mktemp)"
bench() {
  local label=$1 times=() t0 t1 rows found
  shift
  for ((i = 0; i < RUNS; i++)); do
    t0="$(date +%s.%N)"
    times+=("$(curl -fsS -G -o "$body" -w '%{time_total}' "$@")")
    t1="$(date +%s.%N)"
  done
  found="$(jq '(.traces // .series // [.batches // .resourceSpans // empty]) | length' "$body")"
  sql --query "SYSTEM FLUSH LOGS" >/dev/null
  rows="$(sql --query "SELECT formatReadableQuantity(sum(read_rows)) FROM system.query_log
    WHERE type = 'QueryFinish' AND user = 'bench' AND query_kind = 'Select'
      AND event_time_microseconds BETWEEN toDateTime64($t0, 6) AND toDateTime64($t1, 6)")"
  results+=("$(printf '%s\n' "${times[@]}" | sort -n | L="${label//|/\\|}" awk -v r="$rows" -v f="$found" \
    '{a[NR] = $1} END {printf "| %s | %.2f | %.2f | %s | %s |", ENVIRON["L"], a[int((NR + 1) / 2)], a[1], f, r}')")
}

search="{span.http.route=\"/checkout\" && status=error}"
echo "==> Timing $RUNS runs of each request"
bench "trace by ID ($age days old)" "http://localhost:$port/api/traces/$trace_id"
for window in 3600:1h 86400:24h $((DAYS * 86400)):${DAYS}d; do
  bench "\`$search\`, ${window#*:}" "http://localhost:$port/api/search" --data-urlencode "q=$search" \
    --data-urlencode "start=$((now - ${window%%:*}))" --data-urlencode "end=$now" --data-urlencode limit=20
done
# A search that matches nothing reads whatever the indexes can't rule out: the worst case for a rare attribute.
none="{span.http.route=\"/no-such-route\"}"
bench "\`$none\`, ${DAYS}d (no match)" "http://localhost:$port/api/search" --data-urlencode "q=$none" \
  --data-urlencode "start=$((now - DAYS * 86400))" --data-urlencode "end=$now" --data-urlencode limit=20
bench "\`{} | rate() by (resource.service.name)\`, 24h" "http://localhost:$port/api/metrics/query_range" \
  --data-urlencode 'q={} | rate() by (resource.service.name)' --data-urlencode "start=$((now - 86400))" \
  --data-urlencode "end=$now" --data-urlencode step=300

echo
echo "| request | median s | fastest s | found | rows read (last run) |"
echo "|---|---|---|---|---|"
printf '%s\n' "${results[@]}"
