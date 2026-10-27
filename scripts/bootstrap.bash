#!/usr/bin/env bash
# bootstrap.bash <env> [<revision>]: hand the current kube context to Argo CD for one environment.
#   1. make cluster/preflight's checks, which stop on a missing Secret before anything is applied; it never
#      creates passwords (on kind, make cluster/up does that first)
#   2. Argo CD, with cluster-configs/argocd/values.yaml (the child-Application and ClickHouseInstallation
#      health checks), unless an argocd-server is already running, in which case it is left alone
#   3. the environment's AppProject, unless it sets projectCreate: false, then app-of-apps-<env>.yaml
# A <revision> deploys that commit or branch instead of the environment's targetRevision; never commit that.
# KIND_CLUSTER=<name> pulls Argo CD's images on the host first, with retries, and loads them into that kind
# cluster, so a registry hiccup fails in a minute with the image named instead of in the 10m install wait.
# EXTRA_VALUES=<file> merges that file over the environment's values in the bootstrap Application (the
# MESH=istio kind profile uses it); never for a real cluster, whose values belong in its environment file.
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: bootstrap.bash <env> [<revision>]}
revision=${2:-}
values="cluster-configs/overrides/values-$env.yaml"
bootstrap="cluster-configs/app-of-apps/app-of-apps-$env.yaml"
ARGOCD_CHART_VERSION=10.9.2

[[ -f "$bootstrap" ]] || { echo "bootstrap: no $bootstrap; make env/new NAME=$env writes one" >&2; exit 2; }

# preload_kind_images <cluster> <images, one per line>: docker pull each with up to five attempts, then
# kind load it, so the kubelet never pulls it. ecr-public rate-limits anonymous pulls by data volume
# ("Data limit exceeded"), which no retry outlasts, so a Docker official image it refuses
# is pulled from Google's Docker Hub mirror instead: the same manifest, tagged with the chart's name.
preload_kind_images() {
  local cluster=$1 image mirror attempt
  while read -r image; do
    [[ -n "$image" ]] || continue
    mirror=
    [[ $image == ecr-public.aws.com/docker/library/* ]] && mirror="mirror.gcr.io/library/${image#ecr-public.aws.com/docker/library/}"
    for attempt in 1 2 3 4 5; do
      docker pull -q "$image" >/dev/null && break
      if [[ -n "$mirror" ]] && docker pull -q "$mirror" >/dev/null; then
        echo "==> Pulled $mirror instead of $image"
        docker tag "$mirror" "$image"
        break
      fi
      if [[ $attempt == 5 ]]; then
        echo "bootstrap: could not pull $image after 5 attempts" >&2
        return 1
      fi
      echo "==> Pulling $image failed (attempt $attempt); retrying in $((attempt * 10))s" >&2
      sleep $((attempt * 10))
    done
    echo "==> Loading $image into kind"
    kind load docker-image "$image" --name "$cluster" >/dev/null || load_kind_image_archive "$cluster" "$image"
  done <<<"$2"
}

# load_kind_image_archive <cluster> <image>: kind load's docker save exports a multi-platform image's whole
# index from Docker's containerd image store, whose other platforms were never pulled, so the node's import
# fails with "content digest ... not found". Saving only the daemon's own platform gives an archive it can import.
load_kind_image_archive() {
  local cluster=$1 image=$2 archive status=0
  echo "==> Loading $image into kind as a single-platform archive" >&2
  archive="$(mktemp)"
  docker save --platform "linux/$(docker version -f '{{.Server.Arch}}')" -o "$archive" "$image" &&
    kind load image-archive "$archive" --name "$cluster" >/dev/null || status=$?
  rm -f "$archive"
  return "$status"
}

ENV="$env" scripts/preflight.bash

if kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  echo "==> Argo CD is already running; leaving it as it is"
else
  chart_dir="$(mktemp -d)"
  trap 'rm -rf "$chart_dir"' EXIT
  helm pull argo-cd --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
    --destination "$chart_dir"
  chart="$chart_dir/argo-cd-$ARGOCD_CHART_VERSION.tgz"
  if [[ -n "${KIND_CLUSTER:-}" ]]; then
    # Rendered for this cluster's version: helm template otherwise assumes one the chart refuses. Assigned
    # first, so a failed render stops here instead of loading nothing.
    images="$(helm template argocd "$chart" --namespace argocd -f cluster-configs/argocd/values.yaml \
      --kube-version "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" |
      yq -N '.. | select(tag == "!!map" and has("image")) | .image' | sort -u)"
    [[ -n "$images" ]] || { echo "bootstrap: the Argo CD chart rendered no images" >&2; exit 1; }
    preload_kind_images "$KIND_CLUSTER" "$images"
  fi
  echo "==> Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
  helm upgrade --install argocd "$chart" \
    --namespace argocd --create-namespace \
    -f cluster-configs/argocd/values.yaml --wait --timeout 10m
fi

# The bootstrap Application belongs to the project the chart renders, and Argo CD will not sync an
# Application whose project does not exist yet.
if [[ "$(yq '.projectCreate // true' "$values")" != false ]]; then
  echo "==> Applying the $env AppProject"
  helm template app-of-apps cluster-configs/app-of-apps --namespace argocd \
    -f "$values" --show-only templates/app-project.yaml | kubectl apply -f -
fi

echo "==> Applying the $env app-of-apps${revision:+ at $revision}${EXTRA_VALUES:+ with $EXTRA_VALUES}"
application="$(cat "$bootstrap")"
if [[ -n "$revision" ]]; then
  application="$(REVISION="$revision" yq '.spec.source.targetRevision = strenv(REVISION) |
    .spec.source.helm.valuesObject.targetRevision = strenv(REVISION)' <<<"$application")"
fi
if [[ -n "${EXTRA_VALUES:-}" ]]; then
  application="$(yq ea 'select(fileIndex == 0) * {"spec": {"source": {"helm": {"valuesObject": select(fileIndex == 1)}}}}' \
    <(printf '%s\n' "$application") "$EXTRA_VALUES")"
fi
kubectl apply -f - <<<"$application"

cat <<MSG

Argo CD is now syncing $env. Watch progress with:
  kubectl -n argocd get applications -w
MSG
