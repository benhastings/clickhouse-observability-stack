#!/usr/bin/env bash
# cspell:words storageclass
# preflight-test.bash: run preflight.bash for the restricted-namespace profiles against a stub kubectl that answers
# as kind does after scripts/kind-platform.bash: the stack's namespace labelled for Istio injection, every Secret
# present, restricted's shared operator Ready, and a clickhouse-operator namespace that exists without the label
# (scripts/local-secrets.bash creates it).
# Prove standalone and restricted pass there, since neither runs an operator in the stack, and that preflight still
# fails when the stack's own namespace lacks the label. Then prove it refuses a branch as the revision Argo CD would
# follow, and accepts a commit SHA, a tag, or a branch with ALLOW_MUTABLE_REVISION=1.
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
  out="$(PATH="$work/bin:$PATH" ENV="$env" ALLOW_MUTABLE_REVISION=1 scripts/preflight.bash 2>&1)" ||
    fail "$env failed against a namespace labelled as kind-platform.bash labels it: $(grep -E 'FAIL|stub' <<<"$out")"
  echo "preflight-test: ok, $env passes with an unlabelled clickhouse-operator namespace"
done

if out="$(PATH="$work/bin:$PATH" STUB_UNLABELLED=observability ENV=standalone ALLOW_MUTABLE_REVISION=1 scripts/preflight.bash 2>&1)"; then
  fail "standalone passed with the observability namespace unlabelled"
fi
grep -q "namespace observability is not labelled istio-injection=enabled" <<<"$out" ||
  fail "standalone failed for another reason: $(grep -E 'FAIL|stub' <<<"$out")"
echo "preflight-test: ok, standalone fails when the observability namespace is unlabelled"

run() { PATH="$work/bin:$PATH" ENV=standalone "$@" scripts/preflight.bash 2>&1; }
if out="$(run env)"; then
  fail "standalone passed with targetRevision: main, a branch"
fi
grep -q "targetRevision is main, not a commit SHA or a tag" <<<"$out" ||
  fail "standalone failed on a branch for another reason: $(grep -E 'FAIL|stub' <<<"$out")"
grep -q "The render has no clickhouse-operator Application" <<<"$out" ||
  fail "standalone did not say its render has no clickhouse-operator Application"
echo "preflight-test: ok, a branch as the revision fails"

sha="$(git rev-parse HEAD)"
out="$(run env PREFLIGHT_REVISION="$sha")" || fail "standalone failed at commit $sha: $(grep -E 'FAIL|stub' <<<"$out")"
echo "preflight-test: ok, a commit SHA passes"

tag="$(git tag --list | head -1)"
if [[ -n "$tag" ]]; then
  out="$(run env PREFLIGHT_REVISION="$tag")" || fail "standalone failed at tag $tag: $(grep -E 'FAIL|stub' <<<"$out")"
  echo "preflight-test: ok, a tag passes"
else
  echo "preflight-test: skipped the tag case, this checkout has no tags"
fi

if out="$(run env PREFLIGHT_REVISION=feat/some-branch)"; then
  fail "standalone passed with bootstrap's revision a branch"
fi
echo "preflight-test: ok, bootstrap's <revision> is checked in place of the files'"
