#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash
# shellcheck source=scripts/local-secrets.bash
source scripts/local-secrets.bash

# check-local-secrets.bash: render the local environment as Argo CD would, alone and with each tests/mesh
# profile kind-up.sh merges over it, and fail when a pod reads a Secret that neither the render nor
# create_local_secrets creates. Such a pod sits in CreateContainerConfigError on kind, which the golden renders
# don't show: they never include the mesh profiles. An optional reference is allowed.
KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}

# The Secrets kind-up.sh creates, read from create_local_secrets itself.
ensure_secret() { echo "$2"; }
created="$(create_local_secrets | tail -n +2 | sort -u)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failed=0
for profile in "" tests/mesh/*.yaml; do
  extra=()
  [[ -n "$profile" ]] && extra=(-f "$profile")
  label="values-local.yaml${profile:+ + $profile}"
  render_app_of_apps local --kube-version "$KUBE_VERSION" "${extra[@]}" >"$work/app-of-apps.yaml"
  : >"$work/all.yaml"
  while IFS= read -r app; do
    load_app "$work/app-of-apps.yaml" "$app" "$work/values.yaml"
    { helm template "$app_release" "$app_path" --namespace "$app_namespace" --kube-version "$KUBE_VERSION" \
      -f "$work/values.yaml" 2>/dev/null; echo '---'; } >>"$work/all.yaml"
  done < <(app_names "$work/app-of-apps.yaml")

  rendered="$(yq ea 'select(.kind == "Secret") | .metadata.name' "$work/all.yaml" | sort -u)"
  read_names="$(yq ea '[.. | select(has("secretKeyRef")) | .secretKeyRef | select(.optional != true) | .name] +
    [.. | select(has("secretRef")) | .secretRef | select(.optional != true) | .name] +
    [.. | select(has("secret") and (.secret | tag) == "!!map" and (.secret | has("secretName"))) | .secret |
      select(.optional != true) | .secretName] | .[]' "$work/all.yaml" | sort -u)"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "$name" <<<"$created"$'\n'"$rendered"; then
      echo "check-local-secrets: $label: a pod reads Secret $name, which kind never creates" >&2
      failed=1
    fi
  done <<<"$read_names"
  [[ "$failed" == 0 ]] && echo "check-local-secrets: $label: ok"
done
exit "$failed"
