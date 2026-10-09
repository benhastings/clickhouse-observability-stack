# shellcheck shell=bash
# Sourced by kind-up.sh and dev.bash. Credentials are never in git: on kind, create each Secret the
# stack reads once, with a random password, before anything that reads it is installed. An existing
# Secret is left alone, so a re-run keeps its password.

random_password() { od -An -N18 -tx1 /dev/urandom | tr -d ' \n'; }

# ensure_secret <namespace> <name> [kubectl create secret generic args...]
ensure_secret() {
  local namespace=$1 name=$2
  shift 2
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if ! kubectl -n "$namespace" get secret "$name" >/dev/null 2>&1; then
    kubectl -n "$namespace" create secret generic "$name" "$@" >/dev/null
    echo "    created $namespace/$name"
  fi
}

create_local_secrets() {
  echo "==> Creating local credentials"
  ensure_secret observability clickhouse-credentials \
    --from-literal=username=otel --from-literal=password="$(random_password)"
  ensure_secret observability grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(random_password)"
  ensure_secret clickhouse-operator clickhouse-operator-credentials \
    --from-literal=username=clickhouse_operator --from-literal=password="$(random_password)"
}
