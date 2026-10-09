# `common` library chart

<!-- cspell:words daemonset -->

Every Kubernetes object in this stack is rendered by this chart. A chart under `cluster-nodes/` depends on it
with a `file://` dependency, has one template, `templates/common.yaml`, containing
`{{ include "common.all" . }}`, and describes its workload entirely in `values.yaml`.

It is a `type: library` chart, so it has no values of its own: the defaults live in
[`templates/_defaults.tpl`](templates/_defaults.tpl) and are merged under the node's values.

## Why maps instead of lists

Containers, ports, env vars, volumes, ConfigMaps, Secrets and objects are all **maps keyed by name**, not lists.
Helm deep-merges maps but replaces lists, so with maps an environment override can change one field:

```yaml
deployment:
  containers:
    cerberus:
      resources:
        limits:
          memory: 1Gi
```

It doesn't have to restate the whole container. Setting any key to `null` removes it. Maps render in key order,
so the output is deterministic.

## Values reference

| Key | Default | What it does |
| --- | --- | --- |
| `nameOverride` | release name | base name of every object |
| `global.mesh` | `istio` | the service mesh the cluster runs: `istio` or `kubernetes`; anything else fails the render. With exposure on, `istio` renders a Gateway and VirtualService per app, `kubernetes` an Ingress |
| `global.exposure.enabled` | `false` | make the apps that set `exposure.host` reachable from outside the cluster |
| `global.exposure.hosts.<key>` | `{}` | the hostname for each key an app can name in `exposure.host`, such as `grafana` or `otlp`; an enabled exposure fails the render when an app's host is empty |
| `global.exposure.ingressClassName` | `""` | the Ingress class; empty uses the cluster default |
| `global.exposure.tls.credentialName` | `""` | a TLS Secret the site creates, used for every exposed host; empty serves plain HTTP. With Istio, the Secret lives in the ingress gateway's namespace (usually `istio-system`) |
| `global.exposure.gateway.name` | `""` | with `istio`, an existing Gateway to bind every VirtualService to; no Gateway is rendered. Empty gives each app its own Gateway for its own host (443 with a TLS credential, 80 without) |
| `global.exposure.gateway.namespace` | release namespace | the namespace of that existing Gateway |
| `global.exposure.gateway.selector` | `{istio: ingressgateway}` | which ingress gateway pods the rendered Gateways select |
| `global.namespace` | release namespace | namespace of every namespaced object |
| `global.labels` | `{}` | extra labels on every object |
| `global.imageRegistry` | `""` | prepended to every image, so `registry.example/mirror` turns `grafana/grafana:13.2.2` into `registry.example/mirror/grafana/grafana:13.2.2`. An image that names its own registry keeps it in the path (`registry.example/mirror/ghcr.io/...`), which is how pull-through mirrors lay them out. Empty uses each image as written. Nodes that render images outside the common Deployment, such as ClickHouse's Installation and backup job, use the same `common.image` helper |
| `global.imagePullSecrets` | `[]` | Secret names put on every pod that sets no `imagePullSecrets` of its own. A workload's list replaces this one, as Helm does for lists |
| `serviceAccount.create` | `true` | render a ServiceAccount named after the chart |
| `serviceAccount.name` | chart name, or `default` when not created | override the name |
| `serviceAccount.automountToken` | `false` | also applied to the pod spec |
| `serviceAccount.annotations` | `{}` | |
| `rbac.clusterRules` | `[]` | when set, a ClusterRole and ClusterRoleBinding for the ServiceAccount |
| `rbac.rules` | `[]` | when set, a Role and RoleBinding in the release namespace |
| `deployment.enabled` | `false` | render a Deployment |
| `deployment.replicas` | `1` | omitted when `autoscaling.enabled`; see Disruption budget and autoscaling |
| `deployment.strategy` | `RollingUpdate` | |
| `deployment.podLabels`, `deployment.podAnnotations` | `{}` | |
| `deployment.podSecurityContext` | `{}` | |
| `deployment.terminationGracePeriodSeconds` | `30` | |
| `deployment.reloader` | `false` | annotate the Deployment for Stakater Reloader, so a changed Secret or ConfigMap rolls it; see Rollouts |
| `deployment.nodeSelector` | `{}` | passed through to the pod spec; omitted when empty |
| `deployment.affinity` | `{}` | passed through to the pod spec; omitted when empty |
| `deployment.tolerations` | `[]` | passed through to the pod spec; omitted when empty |
| `deployment.topologySpreadConstraints` | `[]` | passed through to the pod spec; omitted when empty |
| `deployment.priorityClassName` | `""` | omitted when empty |
| `deployment.runtimeClassName` | `""` | omitted when empty |
| `deployment.imagePullSecrets` | `[]` | a list of Secret names, rendered as `{name: <secret>}` entries; replaces `global.imagePullSecrets`, and omitted when both are empty |
| `deployment.containers.<name>` | | see Containers below |
| `deployment.volumes.<name>` | | a volume source, such as `configMap: {name: ...}` or `emptyDir: {}`; templated. A string is templated and used as the whole source, so it can hold an `if` |
| `daemonset.enabled` | `false` | render a DaemonSet; see DaemonSet below |
| `daemonset.updateStrategy` | `RollingUpdate` | |
| `daemonset.selectorLabels` | `{}` | merged over the base selector labels on the DaemonSet's selector and pods |
| `daemonset.podLabels` … `daemonset.volumes` | as `deployment` | the same pod, scheduling, container and volume keys as `deployment`, except `replicas` and `strategy` |
| `podDisruptionBudget.enabled` | `false` | render a `policy/v1` PodDisruptionBudget selecting the Deployment's pods |
| `podDisruptionBudget.minAvailable` | `1` | a count or a percentage; set to `null` to use `maxUnavailable` |
| `podDisruptionBudget.maxUnavailable` | unset | a count or a percentage; mutually exclusive with `minAvailable` |
| `autoscaling.enabled` | `false` | render an `autoscaling/v2` HorizontalPodAutoscaler targeting the Deployment |
| `autoscaling.minReplicas` | `2` | |
| `autoscaling.maxReplicas` | `6` | |
| `autoscaling.targetCPUUtilizationPercentage` | `70` | average CPU utilization, relative to the containers' CPU requests |
| `service.enabled` | `false` | render a Service selecting the Deployment's pods |
| `service.type` | `ClusterIP` | |
| `service.annotations` | `{}` | |
| `service.ports.<name>` | | `port`, `targetPort` (defaults to the port name), `protocol` (`TCP`), `appProtocol` |
| `exposure.host` | `""` | the key under `global.exposure.hosts` this app is reachable on, once `global.exposure.enabled` is true: an Ingress with `global.mesh: kubernetes`, a Gateway and VirtualService with `istio` |
| `exposure.port` | `""` | the name of the `service.ports` entry the host routes to |
| `exposure.annotations` | `{}` | annotations on the Ingress, such as a controller's body-size limit |
| `configMaps.<key>` | | a ConfigMap: `data` (map of file name to a string or a YAML object, templated) and/or `files` (a glob relative to the node chart, not templated) |
| `secrets.<key>` | | a Secret: `stringData` (templated), `type` (`Opaque`), `create` (`true`) |
| `objects.<key>` | | any other manifest, such as a custom resource; templated, with name, namespace and labels filled in; skipped when the body renders empty |
| `vault.enabled` | `false` | deliver every container's `secretEnv` through the Vault Agent Injector instead of `secretKeyRef`; see Secrets below |
| `vault.role` | chart name | the Vault Kubernetes auth role the pod logs in as |
| `vault.path` | `secret/data` | KV v2 prefix; a secret is read from `<path>/<secretEnv.secret>` |
| `vault.annotations` | `{}` | extra `vault.hashicorp.com/*` pod annotations, such as `agent-pre-populate-only` |
| `global.vault` | | the same keys for every node at once; a node's own `vault` wins |

A ConfigMap, Secret or object keyed `main` takes the chart's name; any other key is appended, so
`secrets.credentials` in the `clickhouse` node is the Secret `clickhouse-credentials`.

### Containers

| Key | What it does |
| --- | --- |
| `image.repository`, `image.tag` | required |
| `image.pullPolicy` | defaults to `IfNotPresent` |
| `command`, `args` | lists; `args` is templated |
| `ports.<name>` | `containerPort`, `protocol` (`TCP`) |
| `env.<NAME>` | a string (templated), or a map such as `valueFrom: ...` |
| `secretEnv.<NAME>` | a secret the container needs: `secret` (Secret name, templated) and `key`; see Secrets below |
| `envFrom` | list, templated |
| `startupProbe`, `livenessProbe`, `readinessProbe` | passed through |
| `resources`, `securityContext`, `volumeMounts` | passed through |

### Secrets

Declare a secret once, under the container's `secretEnv`, and `vault.enabled` decides how it is delivered:

```yaml
secretEnv:
  GF_SECURITY_ADMIN_PASSWORD:
    secret: '{{ include "common.fullname" . }}-admin'
    key: admin-password
    vault:
      env: GF_SECURITY_ADMIN_PASSWORD__FILE
```

- **`vault.enabled: false`** renders `GF_SECURITY_ADMIN_PASSWORD` with `valueFrom.secretKeyRef` for that Secret
  and key.
- **`vault.enabled: true`** renders no `secretKeyRef`. Instead it adds Vault Agent Injector annotations to the
  pod, so the agent reads field `key` of `<vault.path>/<secret>` and writes it to a file. The pod also gets
  `automountServiceAccountToken: true`, because the agent logs in with the pod's ServiceAccount token. The
  entry's `vault` map says how the app finds the file:

| Key | Default | What it does |
| --- | --- | --- |
| `vault.file` | `/vault/secrets/<secret>-<key>` | where the agent writes it; a directory other than `/vault/secrets` gets its own injected volume |
| `vault.yamlKey` | | write `a.b: <value>` as nested YAML, for apps that read a config file, instead of the bare value |
| `vault.env` | | set this env var to the file's path, for apps with a `_FILE` convention |

With neither `vault.env` nor `vault.yamlKey`, the app's config points at the file itself. Use
`{{ include "common.secretFile" (list . "<container>" "<NAME>") }}` to get the path, and
`{{ if include "common.vaultEnabled" . }}` to switch on the mode; `common.secretFile` looks the container up in
`deployment`, then `daemonset`. Deployment and DaemonSet pods are injected the same way, each from its own
containers' `secretEnv`, and a pod with no `secretEnv` gets no agent.

### Templating

String values in the places marked templated go through `tpl`, so they can use `{{ .Release.Name }}` or
`{{ include "common.fullname" . }}`. Content that contains literal `{{`, such as a Grafana dashboard's legend
format, belongs in a `files` glob, which is not templated.

### Rollouts

Every pod carries a `checksum/config` annotation hashed from the chart's rendered ConfigMaps and Secrets, so a
config change rolls the Deployment and the DaemonSet. A Secret changed outside the chart, or in Vault, does not roll
them, because the chart never sees its data.

For a Secret in the cluster, set `deployment.reloader: true` (or `daemonset.reloader: true`). The workload then
carries `reloader.stakater.com/auto: "true"`, and [Stakater Reloader](https://github.com/stakater/Reloader) rolls it
when a Secret or ConfigMap it reads changes. The cluster has to run Reloader; the stack doesn't install it. A secret
rotated in Vault isn't a Kubernetes object Reloader can watch, so roll the app by hand with
`make cluster/restart APP=<app>`.

### DaemonSet

`daemonset` renders one pod per node, for agents such as a collector reading the kubelet. It takes the same pod
keys as `deployment` and renders them with the same pod template and container helper, so a container is
written the same way in either. It has `updateStrategy` instead of `replicas` and `strategy`, and the
disruption budget and autoscaler never target it.

A chart may enable either kind, both, or neither. Both kinds select their pods with the base labels
`app.kubernetes.io/name` and `app.kubernetes.io/instance`; the DaemonSet merges `daemonset.selectorLabels` over
them. With both enabled the render fails when the two selectors are equal, since the two controllers would select
exactly the same pods, so a chart that runs both sets something like
`daemonset.selectorLabels: {app.kubernetes.io/component: agent}`. The Service still selects on the base
labels, which the DaemonSet's pods also carry; to keep Service traffic off them, override
`app.kubernetes.io/name` in `daemonset.selectorLabels` instead of adding a key.

### Disruption budget and autoscaling

Both render only when `deployment.enabled` is also true, and both are off by default, so a node gains no
objects until an environment turns them on.

`podDisruptionBudget` defaults to `minAvailable: 1`. To use `maxUnavailable` instead, set `minAvailable` to
`null` in the same place; the render fails when both are set, since Kubernetes accepts only one.

When `autoscaling.enabled` is true, the HorizontalPodAutoscaler owns the replica count, so the Deployment is
rendered without `spec.replicas` (otherwise every Argo CD sync would reset it). Size the workload with
`autoscaling.minReplicas` and `autoscaling.maxReplicas`. The render fails if `deployment.replicas` is anything
other than the default `1` while autoscaling is on, because that value would be silently ignored. CPU
utilization is measured against the containers' CPU requests, so every container needs one.

## Tests

`tests/charts/common-fixture` is a small application chart that turns on every feature, and its
`tests/*_test.yaml` are [helm-unittest](https://github.com/helm-unittest/helm-unittest) suites. Run them with
`make test/unit`. A change to a template here needs a test there.
