# Rendered manifests: dev

Generated; do not edit or push to this branch by hand. The `render-dev` workflow rewrites it from
`main` on every push, as one commit per render.

- Source: https://github.com/benhastings/clickhouse-observability-stack/commit/c2cec6a145daa5e0848dfb2c3f8f2ad39c993e49
- Environment: `cluster-configs/overrides/values-dev.yaml`
- Layout: `<namespace>/<kind>-<name>.yaml`, CRDs included, no Argo CD Applications

Apply it with `kubectl apply -R -f .` (the CRDs and the operator first, so apply twice on a new cluster),
or track it with a directory Application. Secrets are not here: create them in the cluster first.
