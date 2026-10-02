#!/usr/bin/env bash
# Forward Grafana, Cerberus, the OTel Collector and, when installed, Argo CD to
# localhost.
# Ctrl+C stops all of them.
set -euo pipefail
trap 'kill 0' EXIT

kubectl -n observability port-forward svc/grafana 3000:80 >/dev/null &
kubectl -n observability port-forward svc/cerberus 8081:8080 >/dev/null &
kubectl -n observability port-forward svc/otel-collector 4317:4317 4318:4318 >/dev/null &

echo "Grafana     http://localhost:3000   (admin / admin)"
# make dev/up runs without Argo CD.
if kubectl get namespace argocd >/dev/null 2>&1; then
  kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null &
  echo "Argo CD     http://localhost:8080   (admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
fi
cat <<MSG
Cerberus    http://localhost:8081   (Prometheus / Loki / Tempo APIs)
OTLP        localhost:4317 (gRPC), http://localhost:4318 (HTTP)
Press Ctrl+C to stop.
MSG
wait
