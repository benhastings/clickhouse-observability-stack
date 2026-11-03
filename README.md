# Rendered manifests: dev

Generated; do not edit or push to this branch by hand. The `render-dev` workflow rewrites it from
`main` on every push, as one commit per render.

- Source: https://github.com/benhastings/clickhouse-observability-stack/commit/f718726373b0b556fdc4e91a3d11f1a9099126c7
- Environment: `cluster-configs/overrides/values-dev.yaml`
- Layout: `<namespace>/<kind>-<name>.yaml`, CRDs included, no Argo CD Applications

Apply it with `kubectl apply -R -f .` (the CRDs and the operator first, so apply twice on a new cluster),
or track it with a directory Application. Secrets are not here: create them in the cluster first.
