#!/usr/bin/env bash
# cspell:words storageclass
# preflight-test.bash: run preflight.bash for the restricted-namespace profiles against a stub kubectl that answers
# as kind does after scripts/kind-platform.bash: the stack's namespace labelled for Istio injection, every Secret
# present, restricted's shared operator Ready, and a clickhouse-operator namespace that exists without the label
# (scripts/local-secrets.bash creates it).
# Prove standalone and restricted pass there, since neither runs an operator in the stack, and that preflight still
# fails when the stack's own namespace lacks the label.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/preflight-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "preflight-test: $1"; exit 1; }

mkdir "$work/bin"
cat >"$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# A stub of the kubectl calls preflight.bash makes. STUB_UNLABELLED names a namespace to serve without labels.
args=" $* "
namespace_json() {
  if [[ "$1" == "${STUB_UNLABELLED:-}" || "$1" == clickhouse-operator ]]; then
    printf '{"metadata": {"name": "%s", "labels": {}}}\n' "$1"
  else
    printf '{"metadata": {"name": "%s", "labels": {"istio-injection": "enabled"}}}\n' "$1"
  fi
}
case "$args" in
  *" config current-context "*) echo kind-stub ;;
  *" get --raw=/version "*) echo '{}' ;;
  *" version -o json "*) echo '{"serverVersion": {"gitVersion": "v9.99.0"}}' ;;
  *" auth can-i "*) echo yes ;;
  *" get namespace "*) ns="${args#* get namespace }"; namespace_json "${ns%% *}" ;;
  *" get --raw /apis/networking.istio.io/v1 "*) echo '{"resources": [{"name": "gateways"}, {"name": "virtualservices"}]}' ;;
  *" get --raw /apis/clickhouse.altinity.com/v1 "*) echo '{"resources": [{"name": "clickhouseinstallations"}]}' ;;
  *" get pods "*) echo '{"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}]}' ;;
  *" get configmap "*) echo '{"data": {"ca.crt": "-----BEGIN CERTIFICATE-----"}}' ;;
  *" get sc -o name "*) echo storageclass.storage.k8s.io/standard ;;
  *" get secret "* | *" get serviceaccount "* | *" get sc "*) ;;
  *) echo "kubectl stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/kubectl"

for env in standalone restricted; do
  out="$(PATH="$work/bin:$PATH" ENV="$env" scripts/preflight.bash 2>&1)" ||
    fail "$env failed against a namespace labelled as kind-platform.bash labels it: $(grep -E 'FAIL|stub' <<<"$out")"
  echo "preflight-test: ok, $env passes with an unlabelled clickhouse-operator namespace"
done

if out="$(PATH="$work/bin:$PATH" STUB_UNLABELLED=observability ENV=standalone scripts/preflight.bash 2>&1)"; then
  fail "standalone passed with the observability namespace unlabelled"
fi
grep -q "namespace observability is not labelled istio-injection=enabled" <<<"$out" ||
  fail "standalone failed for another reason: $(grep -E 'FAIL|stub' <<<"$out")"
echo "preflight-test: ok, standalone fails when the observability namespace is unlabelled"
