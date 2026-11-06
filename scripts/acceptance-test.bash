#!/usr/bin/env bash
# cspell:words statefulsets endpointslices replicasets replicaset
# acceptance-test.bash: run acceptance.bash for standalone against a stub kubectl and curl (make test/acceptance-stub).
# The stub answers as a healthy standalone namespace does, and with STUB_BROKEN=1 as a broken one: ClickHouse's pod
# waiting on a deleted clickhouse-admin Secret, so its Deployment is unready, its Service has no endpoints and the
# schema Job never finishes; a pod stuck in vault-agent-init; the server's certificate not verifying; Cerberus's
# ReplicaSet refused by the namespace quota; the collector accepting OTLP but nothing read back; and no Grafana login
# given. With STUB_ANY_NAME=1 the certificate verifies under any name, which the wrong-name check must catch. Prove the healthy one passes every check and writes its report,
# and the broken one fails exactly the checks docs/tenant-acceptance.md lists for it.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "acceptance-test: $1"; exit 1; }

mkdir "$work/bin"
cat >"$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# A stub of the kubectl calls acceptance.bash makes, for the standalone environment in namespace observability.
args=" $* "
broken="${STUB_BROKEN:-}"
condition() { printf '{"type": "%s", "status": "True", "reason": "%s"}' "$1" "${2:-$1}"; }
case "$args" in
  *" config current-context "*) echo kind-stub ;;
  *" get serviceaccount default "*) ;;
  *" port-forward "*)
    echo "Forwarding from 127.0.0.1:1 -> ${args##*:}"
    exec sleep 60 ;;
  *" -n argocd get applications "*)
    health=Healthy
    [[ -z "$broken" ]] || health=Degraded
    jq -n --arg health "$health" '{items: ([
      {name: "app-of-apps-standalone", labels: {}}, {name: "cerberus-standalone", labels: {environment: "standalone"}},
      {name: "clickhouse-standalone", labels: {environment: "standalone"}}] | map({metadata: ., spec: {source: {targetRevision: "main"}},
      status: {sync: {status: "Synced", revision: "0123abcd"}, health: {status: (if .name == "clickhouse-standalone" then $health else "Healthy" end)}}}))}' ;;
  *" get deployments,statefulsets "*)
    ready=1
    [[ -z "$broken" ]] || ready=0
    jq -n --argjson ready "$ready" '{items: [
      {kind: "Deployment", metadata: {name: "clickhouse"}, spec: {replicas: 1, template: {spec: {containers: [{image: "clickhouse/clickhouse-server:26.9.27.3"}]}}},
        status: {readyReplicas: $ready, updatedReplicas: 1}},
      {kind: "Deployment", metadata: {name: "cerberus"}, spec: {replicas: 1, template: {spec: {containers: [{image: "cerberus:1.0.0"}]}}},
        status: {readyReplicas: $ready, updatedReplicas: $ready}}]}' ;;
  *" get jobs "*)
    if [[ -n "$broken" ]]; then status='{"active": 1}'; else status="{\"conditions\": [$(condition Complete)]}"; fi
    echo "{\"items\": [{\"metadata\": {\"name\": \"clickhouse-schema-f64b48da\", \"labels\": {\"app.kubernetes.io/name\": \"clickhouse-schema\"}}, \"status\": $status}]}" ;;
  *" get deployment clickhouse "*) if [[ -n "$broken" ]]; then echo False; else echo True; fi ;;
  *" get endpointslices "*)
    if [[ -n "$broken" ]]; then echo '{"items": [{"endpoints": []}]}'
    else echo '{"items": [{"endpoints": [{"conditions": {"ready": true}}]}]}'; fi ;;
  *" get configmap platform-ca-bundle "*) echo '{"data": {"ca.crt": "-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----"}}' ;;
  *" get service clickhouse "*)
    echo '{"spec": {"ports": [{"port": 8443, "targetPort": "tcp-https"}, {"port": 9440, "targetPort": "tcp-native"}]}}' ;;
  *" get pods "*)
    if [[ -n "$broken" ]]; then
      echo '{"items": [{"metadata": {"name": "clickhouse-7d9f"}, "status": {"phase": "Pending", "containerStatuses": [
        {"state": {"waiting": {"reason": "CreateContainerConfigError", "message": "secret \"clickhouse-admin\" not found"}}}]}},
        {"metadata": {"name": "grafana-6c4d"}, "spec": {"initContainers": [{"name": "vault-agent-init"}]}, "status": {"phase": "Pending",
          "initContainerStatuses": [{"name": "vault-agent-init", "state": {"running": {}}}]}}]}'
    else
      echo '{"items": [{"metadata": {"name": "clickhouse-7d9f"}, "status": {"phase": "Running", "containerStatuses": [{"state": {"running": {}}}]}},
        {"metadata": {"name": "grafana-6c4d"}, "spec": {"initContainers": [{"name": "vault-agent-init"}]}, "status": {"phase": "Running",
          "initContainerStatuses": [{"name": "vault-agent-init", "state": {"terminated": {"exitCode": 0}}}]}}]}'
    fi ;;
  *" get events "*)
    if [[ -n "$broken" ]]; then
      jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{items: [{reason: "FailedCreate", lastTimestamp: $t,
        involvedObject: {kind: "Job", name: "clickhouse-schema-f64b48da"},
        message: "pods \"clickhouse-schema-f64b48da-x\" is forbidden: exceeded quota: compute, requested: limits.cpu=500m"}]}'
    else
      # A refusal the Job has since recovered from, and one older than the window.
      jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{items: [{reason: "FailedCreate", lastTimestamp: $t,
        involvedObject: {kind: "Job", name: "clickhouse-schema-f64b48da"}, message: "pods is forbidden: exceeded quota: compute"},
        {reason: "FailedCreate", lastTimestamp: "2020-01-01T00:00:00Z",
        involvedObject: {kind: "StatefulSet", name: "old"}, message: "pods is forbidden: exceeded quota: compute"}]}'
    fi ;;
  *" get replicasets "*)
    if [[ -n "$broken" ]]; then
      echo '{"items": [{"metadata": {"name": "cerberus-5c6b"}, "spec": {"replicas": 1}, "status": {"conditions": [
        {"type": "ReplicaFailure", "status": "True", "message": "pods \"cerberus-5c6b-x\" is forbidden: exceeded quota: compute"}]}}]}'
    else
      echo '{"items": [{"metadata": {"name": "cerberus-5c6b"}, "spec": {"replicas": 1}, "status": {}}]}'
    fi ;;
  *) echo "kubectl stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
# A stub of Cerberus, Grafana's datasource proxy and the collector. Healthy, it returns the probe acceptance.bash
# sent; with STUB_BROKEN=1 it accepts the probe and returns nothing.
url="" run=""
for arg in "$@"; do
  case "$arg" in
    http*) url="$arg" ;;
    query=*) [[ "$arg" =~ run=\"([0-9a-f]+)\" ]] && run="${BASH_REMATCH[1]}" ;;
  esac
done
case "$url" in
  */v1/traces | */v1/logs | */v1/metrics) exit 0 ;;
esac
if [[ -n "${STUB_BROKEN:-}" ]]; then
  case "$url" in
    */api/traces/*) echo '{"batches": []}' ;;
    *) echo '{"data": {"result": []}}' ;;
  esac
  exit 0
fi
case "$url" in
  */api/traces/*) echo '{"batches": [{"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "acceptance-probe"}}]}}]}' ;;
  */loki/api/v1/query_range) jq -nc --arg run "$run" '{data: {result: [{values: [["1", ("acceptance probe " + $run)]]}]}}' ;;
  */api/v1/query) echo '{"data": {"result": [{"value": [1, "42"]}]}}' ;;
  *) echo "curl stub: unexpected URL: $url" >&2; exit 22 ;;
esac
STUB
# A stub of openssl s_client against the server: healthy, its certificate verifies only as clickhouse; with
# STUB_BROKEN=1 never; with STUB_ANY_NAME=1 under any name. Anything else is the real openssl (acceptance.bash's
# openssl rand).
cat >"$work/bin/openssl" <<STUB
#!/usr/bin/env bash
[[ "\$1" == s_client ]] || exec $(command -v openssl) "\$@"
name=""
while (("\$#")); do [[ "\$1" == -verify_hostname ]] && name="\$2"; shift; done
if [[ -z "\${STUB_BROKEN:-}" && ( "\$name" == clickhouse || -n "\${STUB_ANY_NAME:-}" ) ]]; then
  echo "Verify return code: 0 (ok)"
else
  echo "Verify return code: 62 (hostname mismatch)"; exit 1
fi
STUB
chmod +x "$work/bin/kubectl" "$work/bin/curl" "$work/bin/openssl"

report="$work/healthy.md"
out="$(PATH="$work/bin:$PATH" REPORT="$report" GRAFANA_AUTH=admin:stub scripts/acceptance.bash standalone 2>&1)" ||
  fail "standalone failed against a healthy namespace: $(grep -E '^FAIL|stub' <<<"$out")"
grep -q '^SKIP' <<<"$out" && fail "a check was skipped against a healthy namespace: $(grep '^SKIP' <<<"$out")"
grep -q 'Result: \*\*PASS\*\*' "$report" || fail "the report does not record a PASS"
grep -q '| clickhouse-standalone | Synced / Healthy | main | 0123abcd |' "$report" ||
  fail "the report does not record the deployed revisions"
grep -q 'admin:stub' "$report" && fail "the report holds the Grafana login"
grep -q 'Rollback revision: not recorded' "$report" || fail "the report does not say the rollback revision is not recorded"
grep -q '| Deployment/clickhouse | clickhouse/clickhouse-server:26.9.27.3 | none |' "$report" ||
  fail "the report does not record how each workload gets its credentials"
echo "acceptance-test: ok, a healthy standalone namespace passes all $(grep -c '^PASS' <<<"$out") checks and the report records its revisions"

if out="$(PATH="$work/bin:$PATH" REPORT="$work/broken.md" STUB_BROKEN=1 ACCEPTANCE_TIMEOUT=0 \
  scripts/acceptance.bash standalone 2>&1)"; then
  fail "standalone passed against a broken namespace"
fi
expected=(
  "Argo CD: every Application of standalone is Synced and Healthy"
  "Workloads: every Deployment and StatefulSet in observability is ready"
  "ClickHouse: ready"
  "ClickHouse: Service clickhouse has ready endpoints"
  "ClickHouse: the server's certificate verifies as clickhouse against the platform's CA"
  "ClickHouse: the schema Job completed"
  "Secrets: no pod waits on a missing Secret"
  "Vault: no pod is stuck on Vault injection"
  "Quota: no pod creation in observability is refused by the quota or admission"
  "Cerberus: reads the synthetic trace (TraceQL API)"
  "Cerberus: reads the synthetic log (LogQL)"
  "Cerberus: reads the synthetic metric (PromQL)"
  "Cerberus: reads the synthetic span's span metrics (PromQL)"
  "Grafana: the Tempo datasource opens the synthetic trace"
  "Grafana: the Loki datasource finds the synthetic log"
  "Grafana: the Prometheus datasource reads the synthetic metric"
  "Grafana: the Prometheus datasource reads the synthetic span's span metrics"
)
actual="$(sed -n 's/^FAIL: \(.*\) | .*$/\1/p' <<<"$out")"
[[ "$actual" == "$(printf '%s\n' "${expected[@]}")" ]] ||
  fail "a broken namespace failed other checks than expected:"$'\n'"$(diff <(printf '%s\n' "${expected[@]}") - <<<"$actual")"
grep -q 'secret "clickhouse-admin" not found' <<<"$out" || fail "the missing Secret is not named"
grep -q 'replicaset/cerberus-5c6b: .*exceeded quota: compute' <<<"$out" || fail "the ReplicaSet's quota refusal is not named"
grep -q 'job/clickhouse-schema-f64b48da: .*exceeded quota: compute' <<<"$out" || fail "the Job's quota refusal is not named"
grep -q 'pod/grafana-6c4d: vault-agent-init still running' <<<"$out" || fail "the pod stuck on Vault injection is not named"
grep -q 'Result: \*\*FAIL\*\*, 4 passed, 17 failed' "$work/broken.md" || fail "the report does not record the failures: $(grep Result "$work/broken.md")"
echo "acceptance-test: ok, a broken standalone namespace fails the ${#expected[@]} checks it should, and only those"

if out="$(PATH="$work/bin:$PATH" REPORT="$work/any-name.md" STUB_ANY_NAME=1 GRAFANA_AUTH=admin:stub ROLLBACK_REVISION=0123abcd \
  scripts/acceptance.bash standalone 2>&1)"; then
  fail "standalone passed with a certificate that verifies under any name"
fi
[[ "$(sed -n 's/^FAIL: \(.*\) | .*$/\1/p' <<<"$out")" == "ClickHouse: the server's certificate does not verify as clickhouse.observability.svc.cluster.local" ]] ||
  fail "a certificate valid under any name failed other checks: $(grep '^FAIL' <<<"$out")"
grep -q 'Rollback revision: 0123abcd' "$work/any-name.md" || fail "the report does not record ROLLBACK_REVISION"
echo "acceptance-test: ok, a certificate that verifies under the cluster-local name fails only that check"
