#!/usr/bin/env bash
# kind-istio.bash [sidecar|ambient]: install a minimal Istio into the current kube context for the MESH=istio
# (sidecar) or MESH=ambient kind profile: the base CRDs, istiod, for ambient also istio-cni and ztunnel, and one
# ingress gateway (istio-ingress/istio-ingressgateway, pods labelled
# istio: ingressgateway, which the stack's Gateways select). The gateway's Service is ClusterIP because kind
# has no load balancer; scripts/e2e.bash reaches it with a port-forward.
set -euo pipefail

ISTIO_VERSION=1.30.5
repo=https://istio-release.storage.googleapis.com/charts

mode=${1:-sidecar}
profile=()
[[ "$mode" != ambient ]] || profile=(--set profile=ambient)

echo "==> Installing Istio $ISTIO_VERSION ($mode)"
helm upgrade --install istio-base base --repo "$repo" --version "$ISTIO_VERSION" \
  --namespace istio-system --create-namespace --wait
helm upgrade --install istiod istiod --repo "$repo" --version "$ISTIO_VERSION" \
  --namespace istio-system --wait --timeout 10m "${profile[@]}" \
  --set resources.requests.cpu=100m --set resources.requests.memory=256Mi
if [[ "$mode" == ambient ]]; then
  # The node agent that redirects each ambient pod's traffic, and ztunnel, which carries it over HBONE.
  helm upgrade --install istio-cni cni --repo "$repo" --version "$ISTIO_VERSION" \
    --namespace istio-system --wait --timeout 10m "${profile[@]}"
  helm upgrade --install ztunnel ztunnel --repo "$repo" --version "$ISTIO_VERSION" \
    --namespace istio-system --wait --timeout 10m
fi
helm upgrade --install istio-ingressgateway gateway --repo "$repo" --version "$ISTIO_VERSION" \
  --namespace istio-ingress --create-namespace --wait --timeout 10m \
  --set service.type=ClusterIP
