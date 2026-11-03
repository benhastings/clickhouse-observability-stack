#!/usr/bin/env bash
# cspell:words tostring
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash
# shellcheck source=scripts/local-secrets.bash
source scripts/local-secrets.bash

# check-kind-profiles.bash: render the local environment as Argo CD would, alone and with each tests/mesh
# profile kind-up.sh merges over it, which the golden renders never include, and fail when
#   - a pod reads a Secret that neither the render nor create_local_secrets creates (an optional reference is
#     allowed): on kind it sits in CreateContainerConfigError
#   - scripts/secret-records.bash, which preflight prints, leaves out a Secret a pod reads
#   - an Istio Gateway serves anything but plain HTTP on 80, which is all e2e reaches the ingress gateway on and
#     all kind can serve: no TLS credential exists there
KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}

# The Secrets kind-up.sh creates, read from create_local_secrets itself.
ensure_secret() { echo "$2"; }
created="$(create_local_secrets | tail -n +2 | sort -u)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Each Istio Gateway server that isn't plain HTTP on 80, as "<gateway> serves <protocol> on <port>".
# shellcheck disable=SC2016 # $name is a yq variable
tls_servers='select(.kind == "Gateway" and .apiVersion == "networking.istio.io/*") |
  .metadata.name as $name | .spec.servers[] | select(.port.number != 80 or .port.protocol != "HTTP") |
  $name + " serves " + .port.protocol + " on " + (.port.number | tostring)'

failed=0
for profile in "" tests/mesh/*.yaml; do
  extra=()
  [[ -n "$profile" ]] && extra=(-f "$profile")
  label="values-local.yaml${profile:+ + $profile}"
  render_app_of_apps local --kube-version "$KUBE_VERSION" "${extra[@]}" >"$work/app-of-apps.yaml"
  : >"$work/all.yaml"
  rm -rf "$work/apps" && mkdir "$work/apps"
  while IFS= read -r app; do
    load_app "$work/app-of-apps.yaml" "$app" "$work/values.yaml"
    helm template "$app_release" "$app_path" --namespace "$app_namespace" --kube-version "$KUBE_VERSION" \
      -f "$work/values.yaml" 2>/dev/null >"$work/apps/$app_release.yaml"
    { cat "$work/apps/$app_release.yaml"; echo '---'; } >>"$work/all.yaml"
  done < <(app_names "$work/app-of-apps.yaml")
  records="$(scripts/secret-records.bash "$work/apps")"

  rendered="$(yq ea 'select(.kind == "Secret") | .metadata.name' "$work/all.yaml" | sort -u)"
  read_names="$(yq ea '[.. | select(has("secretKeyRef")) | .secretKeyRef | select(.optional != true) | .name] +
    [.. | select(has("secretRef")) | .secretRef | select(.optional != true) | .name] +
    [.. | select(has("secret") and (.secret | tag) == "!!map" and (.secret | has("secretName"))) | .secret |
      select(.optional != true) | .secretName] | .[]' "$work/all.yaml" | sort -u)"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "$name" <<<"$created"$'\n'"$rendered"; then
      echo "check-kind-profiles: $label: a pod reads Secret $name, which kind never creates" >&2
      failed=1
    fi
    if ! grep -qxF "$name" <<<"$rendered" && ! grep -qF "Secret $name, " <<<"$records"; then
      echo "check-kind-profiles: $label: a pod reads Secret $name, which secret-records.bash does not list" >&2
      failed=1
    fi
  done <<<"$read_names"
  while IFS= read -r server; do
    [[ -z "$server" ]] && continue
    echo "check-kind-profiles: $label: Istio Gateway $server, but e2e reaches the gateway on plain HTTP 80" >&2
    failed=1
  done < <(yq ea -N "$tls_servers" "$work/all.yaml" | sort -u)
  [[ "$failed" == 0 ]] && echo "check-kind-profiles: $label: ok"
done
exit "$failed"
