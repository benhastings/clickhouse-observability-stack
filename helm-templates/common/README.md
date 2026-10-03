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
| `global.namespace` | release namespace | namespace of every namespaced object |
| `global.labels` | `{}` | extra labels on every object |
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
| `deployment.nodeSelector` | `{}` | passed through to the pod spec; omitted when empty |
| `deployment.affinity` | `{}` | passed through to the pod spec; omitted when empty |
| `deployment.tolerations` | `[]` | passed through to the pod spec; omitted when empty |
| `deployment.topologySpreadConstraints` | `[]` | passed through to the pod spec; omitted when empty |
| `deployment.priorityClassName` | `""` | omitted when empty |
| `deployment.runtimeClassName` | `""` | omitted when empty |
| `deployment.imagePullSecrets` | `[]` | a list of Secret names, rendered as `{name: <secret>}` entries; omitted when empty |
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
| `configMaps.<key>` | | a ConfigMap: `data` (map of file name to a string or a YAML object, templated) and/or `files` (a glob relative to the node chart, not templated) |
| `secrets.<key>` | | a Secret: `stringData` (templated), `type` (`Opaque`), `create` (`true`) |
| `objects.<key>` | | any other manifest, such as a custom resource; templated, with name, namespace and labels filled in; skipped when the body renders empty |

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
| `envFrom` | list, templated |
| `startupProbe`, `livenessProbe`, `readinessProbe` | passed through |
| `resources`, `securityContext`, `volumeMounts` | passed through |

### Templating

String values in the places marked templated go through `tpl`, so they can use `{{ .Release.Name }}` or
`{{ include "common.fullname" . }}`. Content that contains literal `{{`, such as a Grafana dashboard's legend
format, belongs in a `files` glob, which is not templated.

### Rollouts

Every pod carries a `checksum/config` annotation hashed from the chart's rendered ConfigMaps and Secrets, so a
config change rolls the Deployment and the DaemonSet.

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
