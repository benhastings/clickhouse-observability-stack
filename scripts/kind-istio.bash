#!/usr/bin/env bash
# cspell:words httproutes gatewayclass
# kind-istio.bash [sidecar|ambient]: install a minimal Istio into the current kube context for the MESH=istio
# (sidecar) or MESH=ambient kind profile: the base CRDs, istiod, for ambient also istio-cni and ztunnel, and one
# ingress gateway (istio-ingress/istio-ingressgateway, pods labelled
# istio: ingressgateway, which the stack's Gateways select). The gateway's Service is ClusterIP because kind
# has no load balancer; scripts/e2e.bash reaches it with a port-forward.
set -euo pipefail

ISTIO_VERSION=1.30.5
GATEWAY_API_VERSION=v1.7.0
repo=https://istio-release.storage.googleapis.com/charts

mode=${1:-sidecar}
profile=()
[[ "$mode" != ambient ]] || profile=(--set profile=ambient)

echo "==> Installing Istio $ISTIO_VERSION ($mode)"
if [[ "$mode" == ambient ]]; then
  # Before istiod, which sets up its istio GatewayClass for the Gateway API CRDs it finds.
  echo "==> Gateway API $GATEWAY_API_VERSION CRDs"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
  kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io \
    --timeout=60s >/dev/null
fi
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

if [[ "$mode" == ambient ]]; then
  # The ambient profile exposes the stack through Gateway API, as a platform running ambient usually does: the
  # standard CRDs, and one shared Gateway (platform-gateway in istio-ingress, plain HTTP on 80, routes from any
  # namespace), which Istio runs as the platform-gateway-istio Deployment and a ClusterIP Service.
  echo "==> The shared platform-gateway"
  kubectl apply -f - <<'GATEWAY'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: istio-ingress
  annotations:
    # kind has no load balancer to give the Service an address, so the Gateway would never be Programmed.
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
GATEWAY
  if ! kubectl -n istio-ingress wait gateway/platform-gateway --for=condition=Programmed --timeout=300s >/dev/null; then
    kubectl -n istio-ingress get gateway platform-gateway -o yaml | yq '.status' || true
    kubectl get gatewayclass || true
    exit 1
  fi
fi
