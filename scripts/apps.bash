# shellcheck shell=bash
# Sourced by render.bash and dev.bash. Both read the Applications the app-of-apps
# chart generates for an environment, so the golden renders, Argo CD and
# make dev/up give every app the same chart, release, namespace and values.

# render_app_of_apps <env> [helm args...]: the generated Applications on stdout.
render_app_of_apps() {
  local env=$1
  shift
  helm template app-of-apps cluster-configs/app-of-apps --namespace argocd \
    -f "cluster-configs/overrides/values-$env.yaml" "$@"
}

# app_names <app-of-apps.yaml>: one Application name per line, in sync-wave order.
app_names() {
  yq ea '[select(.kind == "Application")]
    | sort_by(.metadata.annotations."argocd.argoproj.io/sync-wave" | to_number)
    | .[].metadata.name' "$1"
}

# load_app <app-of-apps.yaml> <application> <values-file>: writes the
# Application's Helm values to <values-file> and sets app_path, app_release and
# app_namespace.
load_app() {
  local select="select(.metadata.name == \"$2\")"
  yq "$select | .spec.source.helm.valuesObject" "$1" >"$3"
  # shellcheck disable=SC2034 # read by the scripts that source this file
  {
    app_path="$(yq "$select | .spec.source.path" "$1")"
    app_release="$(yq "$select | .spec.source.helm.releaseName" "$1")"
    app_namespace="$(yq "$select | .spec.destination.namespace" "$1")"
  }
}
