#!/usr/bin/env bash
# Run the local stack on kind without Argo CD, straight from the working tree.
#
#   dev.bash up             kind cluster, then every app except demo-load, in sync-wave order
#   dev.bash apply <app>    install or upgrade one app from cluster-nodes/<app>
#   dev.bash remove <app>   uninstall one app
#   dev.bash dashboards     save every dashboard in Grafana to cluster-nodes/grafana/dashboards/
#   dev.bash slack <channel>  send alerts to Slack: the token in SLACK_APP_TOKEN, then Alertmanager with slack on
#   dev.bash garmr-slack <channel ID>  garmr's incidents to Slack: the tokens in SLACK_BOT_TOKEN_FILE and
#                           SLACK_APP_TOKEN_FILE, then garmr with slack on and Alertmanager's own Slack off
#
# Each app gets the release, namespace and values Argo CD would give it in the
# local environment (see apps.bash). Sync waves become install order: helm
# waits for each app, and for a ClickHouseInstallation to be Completed, before
# the next starts.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/apps.bash
source scripts/apps.bash
# shellcheck source=scripts/local-secrets.bash
source scripts/local-secrets.bash

ENV=local
CLUSTER=clickhouse-obs

DASHBOARDS=cluster-nodes/grafana/dashboards

work="$(mktemp -d)"
trap 'rm -rf "$work"; kill $(jobs -p) 2>/dev/null || true' EXIT

use_cluster() {
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "This cluster runs Argo CD, which would undo anything installed here."
    echo "Delete it with make cluster/down, then run make dev/up."
    exit 1
  fi
}

# apply <app> [helm args...]: extra args, such as --set, go after the environment's values.
apply() {
  local app=$1
  shift
  load_app "$work/app-of-apps.yaml" "$app-$ENV" "$work/$app.yaml"
  [[ -n "$app_path" && "$app_path" != null ]] || { echo "unknown app: $app (see cluster-configs/app-of-apps/values.yaml)"; exit 1; }
  echo "==> $app"
  helm upgrade --install "$app_release" "$app_path" --namespace "$app_namespace" --create-namespace \
    -f "$work/$app.yaml" "$@" --wait --timeout 10m
  wait_for_clickhouse "$app_release" "$app_namespace"
}

# Argo CD's health check for a ClickHouseInstallation, as a wait: helm can't
# tell when the operator has finished creating ClickHouse.
wait_for_clickhouse() {
  local chi
  kubectl get crd clickhouseinstallations.clickhouse.altinity.com >/dev/null 2>&1 || return 0
  for chi in $(kubectl -n "$2" get clickhouseinstallations -l "app.kubernetes.io/instance=$1" -o name); do
    echo "    waiting for $chi to be Completed"
    kubectl -n "$2" wait "$chi" --for=jsonpath='{.status.status}'=Completed --timeout=10m
  done
}

# Write each dashboard over the file with the same uid, or to <uid>.json if it's
# new, with sorted keys so diffs show only real changes. id and version belong
# to this Grafana's database, not the dashboard.
export_dashboards() {
  local grafana=http://localhost:13000 auth uid file existing
  auth="$(kubectl -n observability get secret grafana-admin -o json |
    jq -r '.data | "\(."admin-user" | @base64d):\(."admin-password" | @base64d)"')"
  kubectl -n observability port-forward svc/grafana 13000:80 >/dev/null &
  sleep 3
  for uid in $(curl -fsS -u "$auth" "$grafana/api/search?type=dash-db" | jq -r '.[].uid'); do
    file="$DASHBOARDS/$uid.json"
    for existing in "$DASHBOARDS"/*.json; do
      [[ "$(jq -r .uid "$existing")" == "$uid" ]] && file="$existing"
    done
    curl -fsS -u "$auth" "$grafana/api/dashboards/uid/$uid" | jq -S '.dashboard | del(.id, .version)' >"$work/dashboard.json"
    mv "$work/dashboard.json" "$file"
    echo "  $uid -> $file"
  done
  echo "Review with git diff $DASHBOARDS, then make dev/apply APP=grafana to load them as files."
}

render_app_of_apps "$ENV" >"$work/app-of-apps.yaml"

case "${1:-}" in
  up)
    if ! kind get clusters | grep -qx "$CLUSTER"; then
      kind create cluster --config kind-config.yaml
    fi
    use_cluster
    create_local_secrets
    while IFS= read -r name; do
      app="${name%"-$ENV"}"
      # Traffic is opt-in here: make dev/load.
      [[ "$app" == demo-load ]] || apply "$app"
    done < <(app_names "$work/app-of-apps.yaml")
    cat <<'MSG'

The stack is up, with no demo traffic. Next:
  make dev/port-forward     Grafana :3000, Cerberus :8081, OTLP :4317/:4318
  make dev/load             start the demo load
  make dev/apply APP=<app>  redeploy one app after editing it
MSG
    ;;
  apply)
    use_cluster
    apply "${2:?usage: dev.bash apply <app>}"
    ;;
  remove)
    use_cluster
    load_app "$work/app-of-apps.yaml" "${2:?usage: dev.bash remove <app>}-$ENV" "$work/values.yaml"
    helm uninstall "$app_release" --namespace "$app_namespace" --wait
    ;;
  dashboards)
    use_cluster
    export_dashboards
    ;;
  slack)
    # The token is a Slack app's bot token (xoxb-...) with chat:write, invited to the channel. It goes in the
    # Secret alertmanager-slack and nowhere else; the channel is a value.
    channel="${2:?usage: SLACK_APP_TOKEN=xoxb-... dev.bash slack <channel>}"
    : "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN to the bot token of the Slack app}"
    use_cluster
    kubectl -n observability create secret generic alertmanager-slack --from-literal=app-token="$SLACK_APP_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # Slack threads (post_updates_to_thread) are on Alertmanager's main branch but in no release after
    # v0.34.1, so this runs the moving main tag. A digest of it can't be committed: quay.io deletes the old
    # manifest when main moves. Go back to the node's tag once a release has threads.
    apply alertmanager --set slack.enabled=true --set-string slack.channel="$channel" \
      --set-string deployment.containers.alertmanager.image.tag=main
    kubectl -n observability rollout restart deployment/alertmanager >/dev/null
    echo "Alerts now go to $channel, one thread per alert group. Undo with make dev/apply APP=alertmanager."
    ;;
  garmr-slack)
    # garmr's Slack app has a bot token (xoxb-..., chat:write, invited to the channel) and an app-level token
    # (xapp-..., connections:write) for Socket Mode. They go from their files into the Secret garmr-slack and
    # nowhere else; the channel ID is a value.
    channel="${2:?usage: SLACK_BOT_TOKEN_FILE=... SLACK_APP_TOKEN_FILE=... dev.bash garmr-slack <channel ID>}"
    : "${SLACK_BOT_TOKEN_FILE:?set SLACK_BOT_TOKEN_FILE to the file holding the bot token (xoxb-...)}"
    : "${SLACK_APP_TOKEN_FILE:?set SLACK_APP_TOKEN_FILE to the file holding the app-level token (xapp-...)}"
    use_cluster
    kubectl -n observability create secret generic garmr-slack \
      --from-file=bot-token="$SLACK_BOT_TOKEN_FILE" --from-file=app-token="$SLACK_APP_TOKEN_FILE" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # One thread per incident from garmr, so Alertmanager's own Slack threads go off.
    apply alertmanager --set slack.enabled=false
    apply garmr --set slack.enabled=true --set-string slack.channel="$channel"
    kubectl -n observability rollout restart deployment/garmr >/dev/null
    kubectl -n observability rollout status deployment/garmr --timeout=2m >/dev/null
    echo "garmr now posts each incident to $channel. Undo with make dev/apply APP=garmr."
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
