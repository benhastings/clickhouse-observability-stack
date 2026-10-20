# Rendered manifests: dev

Generated; do not edit or push to this branch by hand. The `render-dev` workflow rewrites it from
`main` on every push, as one commit per render.

- Source: https://github.com/benhastings/clickhouse-observability-stack/commit/cd752cd24781ce092d384aba800c4ddafc5ac3b6
- Environment: `cluster-configs/overrides/values-dev.yaml`
- Layout: `<namespace>/<kind>-<name>.yaml`, CRDs included, no Argo CD Applications

Apply it with `kubectl apply -R -f .` (the CRDs and the operator first, so apply twice on a new cluster),
or track it with a directory Application. Secrets are not here: create them in the cluster first.
