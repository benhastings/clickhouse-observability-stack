{{- /* Generated from helm-templates/common/values.yaml by make generate: edit that file, not this one. */ -}}
{{- define "common.defaults" -}}
nameOverride: ""
global:
  mesh: istio
  namespace: ""
  labels: {}
  imageRegistry: ""
  externalSecrets:
    enabled: false
    secretStoreRef:
      name: ""
      kind: ClusterSecretStore
    remotePath: observability
    refreshInterval: 1h
  networkPolicy:
    enabled: false
    # Namespaces whose pods may reach an exposed app: the Istio ingress gateway or the Ingress controller.
    exposureNamespaces: []
    istioNamespace: istio-system
    # Where the stack runs, for rules that cross from the operator's namespace to ClickHouse's.
    namespaces:
      stack: observability
      operator: clickhouse-operator
  # Who runs the Altinity ClickHouse operator. false: this stack installs it, as the clickhouse-operator
  # application with its CRDs, ClusterRole and ClusterRoleBinding. true: a platform team already runs one that
  # watches the stack's namespace (in global.networkPolicy.namespaces.operator), and the stack renders nothing
  # cluster-scoped for ClickHouse. podLabels select the operator's pods, for the NetworkPolicy and preflight.
  clickhouseOperator:
    shared: false
    podLabels:
      app.kubernetes.io/name: clickhouse-operator
  # Who runs ClickHouse. external false: this stack does, through the operator. true: a service owner does, at
  # global.services.clickhouse, and the stack renders no operator and no ClickHouseInstallation (README: An
  # external ClickHouse). An external ClickHouse is always reached over TLS with the server's certificate
  # verified: tls.serverName is the name it must carry and tls.caConfigMap the ConfigMap, in the stack's
  # namespace, with the CA bundle that signed it (key tls.caKey). The platform or the service owner provides that
  # ConfigMap; the stack never creates a certificate, and there is no way to skip verification.
  # networkPolicyPeers are the NetworkPolicy peers the address resolves to; empty allows its port anywhere.
  clickhouse:
    external: false
    networkPolicyPeers: []
    tls:
      serverName: ""
      caConfigMap: ""
      caKey: ca.crt
  # How long the stack keeps each signal, in days: ClickHouse's TTLs (the clickhouse node's schema) and Cerberus's
  # metadata lookback (CERBERUS_PROM_METADATA_LOOKBACK, which must cover the metrics) both read these, so they
  # can't drift apart. Three weeks of traces to search, two of logs, and 90 days of metrics.
  retention:
    traces: 21
    logs: 14
    metrics: 90
  # With mesh: istio, how pods join the mesh. sidecar: an istio-proxy container in each pod (the namespace is
  # labelled istio-injection: enabled). ambient: no sidecar; the node's ztunnel carries every pod's traffic over
  # HBONE (port 15008) with mTLS, and the namespace is labelled istio.io/dataplane-mode: ambient. waypoint names
  # a waypoint the platform already runs, for L7 policy: every Service is labelled to use it. The stack never
  # renders a waypoint, which needs the Gateway API CRDs.
  istio:
    dataplaneMode: sidecar
    waypoint:
      name: ""
      namespace: ""
  # A namespace quota on CPU and memory: true makes check/manifests require a request and a limit for both on every container.
  quota:
    requireLimits: false
  imagePullSecrets: []
  # Every container's requests and limits unless it sets its own, key by key: a container that sets only
  # limits.memory keeps these requests. Sized for a small sidecar-like service; a node writes resources only when
  # its app needs materially more. An environment resizes every app at once here. No CPU limit, so a busy container
  # is throttled by its neighbours' requests rather than a hard cap; a namespace quota that demands one sets it here.
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi
  services:
    clickhouse: clickhouse:9000
    cerberus: http://cerberus:8080
    otlpGrpc: otel-collector:4317
    alertmanager: http://alertmanager:9093
    sqlAdapter: http://garmr-sql-adapter:8080
    garmr: http://garmr:8080
    alertHistory: http://otel-collector:8088/alertmanager
  # Grafana and OTLP over HTTP are reachable on these placeholder hosts: under Istio each app gets its own
  # Gateway on 443 and a VirtualService, and without it an Ingress. Istio reads the TLS Secret credentialName
  # from the ingress gateway's namespace (usually istio-system); the site creates it, for example with
  # cert-manager. To bind to a Gateway the site already runs, set gateway.name and gateway.namespace.
  # api picks how: istio (an Istio Gateway and VirtualService), gateway-api (an HTTPRoute on the platform's Gateway
  # API Gateway, named by gateway.name and gateway.namespace, one listener by gateway.sectionName), or ingress;
  # empty follows the mesh (istio, or ingress without it). scheme is the public URLs' scheme (Grafana's root URL):
  # empty is https with a TLS credential and http without; set https when a platform Gateway terminates TLS.
  exposure:
    enabled: true
    api: ""
    scheme: ""
    hosts:
      grafana: grafana.example.com
      otlp: otlp.example.com
    ingressClassName: ""
    tls:
      credentialName: observability-tls
    gateway:
      name: ""
      namespace: ""
      sectionName: ""
      selector:
        istio: ingressgateway
serviceAccount:
  create: true
  name: ""
  automountToken: false
  annotations: {}
rbac:
  scope: cluster
  clusterRules: []
  rules: []
  namespaceRules: []
deployment:
  enabled: true
  reloader: false
  replicas: 1
  strategy:
    type: RollingUpdate
  podLabels: {}
  podAnnotations: {}
  # Restricted by default; a node sets only what it changes. readOnlyRootFilesystem stays true: a
  # container that writes mounts an emptyDir there, or sets the field false with a comment saying why.
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    privileged: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  terminationGracePeriodSeconds: 30
  nodeSelector: {}
  affinity: {}
  tolerations: []
  topologySpreadConstraints: []
  priorityClassName: ""
  runtimeClassName: ""
  imagePullSecrets: []
  containers: {}
  volumes: {}
daemonset:
  enabled: false
  reloader: false
  updateStrategy:
    type: RollingUpdate
  selectorLabels: {}
  podLabels: {}
  podAnnotations: {}
  # Restricted by default; a node sets only what it changes. readOnlyRootFilesystem stays true: a
  # container that writes mounts an emptyDir there, or sets the field false with a comment saying why.
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    privileged: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  terminationGracePeriodSeconds: 30
  nodeSelector: {}
  affinity: {}
  tolerations: []
  topologySpreadConstraints: []
  priorityClassName: ""
  runtimeClassName: ""
  imagePullSecrets: []
  containers: {}
  volumes: {}
probes:
  livenessProbe:
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 6
  readinessProbe:
    periodSeconds: 5
    timeoutSeconds: 5
  startupProbe: {}
podDisruptionBudget:
  enabled: false
  minAvailable: 1
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
service:
  enabled: true
  type: ClusterIP
  annotations: {}
  ports: {}
networkPolicy:
  enabled: true
  podSelector: {}
  ingress: []
  egress: []
exposure:
  host: ""
  port: ""
  annotations: {}
configMaps: {}
secrets: {}
vault:
  enabled: false
  role: ""
  path: secret/data
  secret: ""
  annotations: {}
objects: {}
{{- end -}}
