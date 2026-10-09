#!/usr/bin/env bash
# check-credentials.bash <dir>...: fail when rendered manifests carry a credential. Two checks:
#   - a Secret with a non-empty value under data or stringData. Real Secrets are created in the cluster,
#     never rendered from git.
#   - a credential-looking key (password, admin-password, client-secret, token, ...) whose value is a
#     literal: not empty and not a reference such as ${env:X}, $__env{X}, $__file{X} or a Helm template.
# A known, non-secret literal is allowed only by an exact line in scripts/check-credentials.allow.
set -euo pipefail
cd "$(dirname "$0")/.."

(($# > 0)) || { echo "usage: check-credentials.bash <dir>..." >&2; exit 2; }
allow=scripts/check-credentials.allow

allowed() { # <file> <trimmed line>
  local glob line
  while IFS=$'\t' read -r glob line; do
    [[ -z "$glob" || "$glob" == \#* ]] && continue
    # shellcheck disable=SC2053 # the allowlist's first column is a glob
    [[ "$1" == $glob && "$2" == "$line" ]] && return 0
  done <"$allow"
  return 1
}

failed=0
while IFS= read -r -d '' file; do
  # Secrets with any non-empty value.
  if leaked="$(yq ea -N 'select(.kind == "Secret") | (.data // {}) + (.stringData // {}) | to_entries | .[] | select((.value // "") != "") | .key' "$file" 2>/dev/null)" && [[ -n "$leaked" ]]; then
    while IFS= read -r key; do
      echo "check-credentials: $file: a Secret carries a value for $key" >&2
      failed=1
    done <<<"$leaked"
  fi
  # Credential-looking keys with a literal value.
  while IFS= read -r hit; do
    lineno=${hit%%:*}
    line="$(sed -E 's/^[[:space:]]*-?[[:space:]]*//; s/[[:space:]]+$//' <<<"${hit#*:}")"
    value="$(sed -E 's/^[^:]+:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//' <<<"$line")"
    # shellcheck disable=SC2016 # literal ${ and {{ mark a reference, not a value
    case "$value" in
      "" | "|"* | ">"* | *'${'* | *'$__env{'* | *'$__file{'* | *'{{'*) continue ;;
    esac
    allowed "$file" "$line" && continue
    echo "check-credentials: $file:$lineno: literal credential: $line" >&2
    failed=1
  done < <(grep -nEi '^[[:space:]]*-?[[:space:]]*"?([a-z0-9_-]*password|client[-_]secret|secret[-_]key|access[-_]key|token)"?[[:space:]]*:' "$file" || true)
done < <(find "$@" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)

if ((failed)); then
  echo "check-credentials: credentials found; create real Secrets in the cluster, never in git" >&2
  exit 1
fi
echo "check-credentials: ok"
