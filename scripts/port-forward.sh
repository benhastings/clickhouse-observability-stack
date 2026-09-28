#!/usr/bin/env bash
# Forward Grafana, Argo CD, Cerberus and the OTel Collector to localhost.
# Ctrl+C stops all of them.
set -euo pipefail
trap 'kill 0' EXIT

kubectl -n observability port-forward svc/grafana 3000:80 >/dev/null &
kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null &
kubectl -n observability port-forward svc/cerberus 8081:8080 >/dev/null &
kubectl -n observability port-forward svc/otel-collector 4317:4317 4318:4318 >/dev/null &

cat <<MSG
Grafana     http://localhost:3000   (admin / admin)
Argo CD     http://localhost:8080   (admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))
Cerberus    http://localhost:8081   (Prometheus / Loki / Tempo APIs)
OTLP        localhost:4317 (gRPC), http://localhost:4318 (HTTP)
Press Ctrl+C to stop.
MSG
wait
