{{- /* cspell:words daemonset */ -}}

{{- define "common.dataEntries" -}}
{{- $root := index . 0 -}}
{{- $data := index . 1 -}}
{{- range $key, $value := $data }}
{{- if not (kindIs "invalid" $value) }}
{{- $text := kindIs "string" $value | ternary (tpl (toString $value) $root) (tpl (toYaml $value) $root) }}
{{- if contains "\n" $text }}
{{ $key }}: |-
  {{- $text | nindent 2 }}
{{- else }}
{{ $key }}: {{ $text | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- /* cspell:words daemonset */ -}}

{{- define "common.daemonsetSelectorLabels" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- toYaml (mustMergeOverwrite (include "common.selectorLabels" . | fromYaml) $v.daemonset.selectorLabels) -}}
{{- end -}}

{{- /* cspell:words daemonset */ -}}

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
  imagePullSecrets: []
  services:
    clickhouse: clickhouse:9000
    cerberus: http://cerberus:8080
    otlpGrpc: otel-collector:4317
  exposure:
    enabled: false
    hosts: {}
    ingressClassName: ""
    tls:
      credentialName: ""
    gateway:
      name: ""
      namespace: ""
      selector:
        istio: ingressgateway
serviceAccount:
  create: true
  name: ""
  automountToken: false
  annotations: {}
rbac:
  clusterRules: []
  rules: []
deployment:
  enabled: false
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
podDisruptionBudget:
  enabled: false
  minAvailable: 1
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
service:
  enabled: false
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
  annotations: {}
objects: {}
{{- end -}}

{{- define "common.values" -}}
{{- $defaults := include "common.defaults" . | fromYaml -}}
{{- $values := mustMergeOverwrite (deepCopy $defaults) (deepCopy .Values.AsMap) -}}
{{- $vault := mustMergeOverwrite $defaults.vault (deepCopy (default (dict) $values.global.vault)) (deepCopy (default (dict) .Values.vault)) -}}
{{- $_ := set $values "vault" $vault -}}
{{- toYaml $values -}}
{{- end -}}

{{- define "common.container" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $c := index . 2 -}}
{{- $key := index . 3 -}}
- name: {{ $name }}
  {{- $_ := required (printf "%s.containers.%s.image.repository is required" $key $name) $c.image.repository }}
  {{- $_ := required (printf "%s.containers.%s.image.tag is required" $key $name) $c.image.tag }}
  image: {{ include "common.image" (list $root $c.image) | quote }}
  imagePullPolicy: {{ $c.image.pullPolicy | default "IfNotPresent" }}
  {{- with $c.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.args }}
  args:
    {{- tpl (toYaml .) $root | nindent 4 }}
  {{- end }}
  {{- with $c.ports }}
  ports:
    {{- range $portName, $port := . }}
    - name: {{ $portName }}
      containerPort: {{ $port.containerPort }}
      protocol: {{ $port.protocol | default "TCP" }}
    {{- end }}
  {{- end }}
  {{- $vaultEnabled := include "common.vaultEnabled" $root -}}
  {{- $env := deepCopy (default (dict) $c.env) -}}
  {{- range $envName, $s := $c.secretEnv }}
  {{- if $s }}
  {{- $secret := tpl (required (printf "%s.containers.%s.secretEnv.%s.secret is required" $key $name $envName) $s.secret) $root -}}
  {{- $secretKey := required (printf "%s.containers.%s.secretEnv.%s.key is required" $key $name $envName) $s.key -}}
  {{- if $vaultEnabled }}
  {{- with (default (dict) $s.vault).env }}
  {{- $_ := set $env . (include "common.secretFilePath" (list $root $s)) -}}
  {{- end }}
  {{- else }}
  {{- $_ := set $env $envName (dict "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" $secretKey))) -}}
  {{- end }}
  {{- end }}
  {{- end }}
  {{- with $env }}
  env:
    {{- range $envName, $envValue := . }}
    {{- if not (kindIs "invalid" $envValue) }}
    - name: {{ $envName }}
      {{- if kindIs "map" $envValue }}
      {{- tpl (toYaml $envValue) $root | nindent 6 }}
      {{- else }}
      value: {{ tpl (toString $envValue) $root | quote }}
      {{- end }}
    {{- end }}
    {{- end }}
  {{- end }}
  {{- with $c.envFrom }}
  envFrom:
    {{- tpl (toYaml .) $root | nindent 4 }}
  {{- end }}
  {{- range $probe := list "startupProbe" "livenessProbe" "readinessProbe" }}
  {{- with index $c $probe }}
  {{ $probe }}:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- with $c.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $workload := index (include "common.values" $root | fromYaml) $key }}
  {{- with mustMergeOverwrite (deepCopy ($workload.containerSecurityContext | default dict)) (deepCopy ($c.securityContext | default dict)) }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.volumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{- define "common.podTemplate" -}}
{{- $root := index . 0 -}}
{{- $key := index . 1 -}}
{{- $d := index . 2 -}}
{{- $selector := index . 3 -}}
{{- $v := include "common.values" $root | fromYaml -}}
metadata:
  labels:
    {{- $selector | nindent 4 }}
    {{- with $d.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    checksum/config: {{ include "common.configChecksum" $root }}
    {{- if include "common.vaultInjected" (list $root $d) }}
    {{- include "common.vaultAnnotations" (list $root $d) | nindent 4 }}
    {{- end }}
    {{- with $d.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "common.serviceAccountName" $root }}
  automountServiceAccountToken: {{ or $v.serviceAccount.automountToken (ne (include "common.vaultInjected" (list $root $d)) "") }}
  {{- with $d.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  terminationGracePeriodSeconds: {{ $d.terminationGracePeriodSeconds }}
  {{- with $d.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with $d.runtimeClassName }}
  runtimeClassName: {{ . }}
  {{- end }}
  {{- with include "common.imagePullSecrets" (list $root $d.imagePullSecrets) | trim }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- with $d.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $d.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $d.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $d.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    {{- if not $d.containers }}
    {{- fail (printf "%s.enabled is true but %s.containers is empty" $key $key) }}
    {{- end }}
    {{- range $name, $c := $d.containers }}
    {{- if $c }}
    {{- include "common.container" (list $root $name $c $key) | nindent 4 }}
    {{- end }}
    {{- end }}
  {{- with $d.volumes }}
  volumes:
    {{- range $name, $volume := . }}
    {{- if $volume }}
    - name: {{ $name }}
      {{- tpl (ternary $volume (toYaml $volume) (kindIs "string" $volume)) $root | trim | nindent 6 }}
    {{- end }}
    {{- end }}
  {{- end }}
{{- end -}}

{{- /*
With global.mesh istio, an app's Service gets a DestinationRule that sends traffic to it over Istio mutual
TLS. PeerAuthentication stays at the mesh default; requiring mTLS (STRICT) is the kind-with-Istio profile.
*/ -}}

{{- /*
With global.externalSecrets.enabled, every secrets.<key> that lists external.keys is materialized by the
External Secrets operator: an ExternalSecret whose target is the same Secret name the pods already read,
filled from <remotePath>/<Secret name> in the store global.externalSecrets.secretStoreRef names, one
property per key. The chart never renders the Secret itself in that mode and never installs the operator
or a store.
*/ -}}

{{- /*
With global.mesh istio, an app that sets exposure.host is reachable through Istio: a VirtualService routes
global.exposure.hosts.<exposure.host> to the app's Service port exposure.port. Each app renders its own
Gateway for its own host, so no app owns another's, unless global.exposure.gateway.name names a Gateway the
site already runs, in which case the VirtualService binds to that and no Gateway is rendered.
*/ -}}

{{- define "common.fullname" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.namespace" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- default .Release.Namespace $v.global.namespace -}}
{{- end -}}

{{- define "common.mesh" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $mesh := toString $v.global.mesh -}}
{{- if not (has $mesh (list "istio" "kubernetes")) -}}
{{- fail (printf "global.mesh must be istio or kubernetes, not %q" $mesh) -}}
{{- end -}}
{{- $mesh -}}
{{- end -}}

{{- define "common.resourceName" -}}
{{- $root := index . 0 -}}
{{- $key := index . 1 -}}
{{- if eq $key "main" -}}
{{- include "common.fullname" $root -}}
{{- else -}}
{{- printf "%s-%s" (include "common.fullname" $root) $key | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "common.serviceAccountName" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if $v.serviceAccount.create -}}
{{- default (include "common.fullname" .) $v.serviceAccount.name -}}
{{- else -}}
{{- default "default" $v.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "common.labels" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{ include "common.selectorLabels" . }}
app.kubernetes.io/part-of: clickhouse-observability-stack
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{- with $v.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "common.metadata" -}}
{{- $root := index . 0 -}}
name: {{ index . 1 }}
namespace: {{ include "common.namespace" $root }}
labels:
  {{- include "common.labels" $root | nindent 2 }}
{{- end -}}

{{- define "common.clusterMetadata" -}}
{{- $root := index . 0 -}}
name: {{ index . 1 }}
labels:
  {{- include "common.labels" $root | nindent 2 }}
{{- end -}}

{{- define "common.configChecksum" -}}
{{- print (include (print .Template.BasePath "/configmap.yaml") .) (include (print .Template.BasePath "/secret.yaml") .) | sha256sum -}}
{{- end -}}

{{- /*
common.image renders <repository>:<tag>, prefixed with global.imageRegistry when it is set. It takes
(list $root $image) so templates outside the common Deployment, such as a node's ClickHouseInstallation,
can use the same mirror.
*/ -}}

{{- define "common.image" -}}
{{- $root := index . 0 -}}
{{- $image := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $ref := printf "%s:%s" $image.repository (toString $image.tag) -}}
{{- with $v.global.imageRegistry -}}
{{- printf "%s/%s" (trimSuffix "/" .) $ref -}}
{{- else -}}
{{- $ref -}}
{{- end -}}
{{- end -}}

{{- /*
common.imagePullSecrets renders an imagePullSecrets list for a pod spec: the workload's own list, or
global.imagePullSecrets when the workload sets none. A workload's list replaces the global one, as Helm
does for every list. It takes (list $root $workloadList) and renders nothing when both are empty.
*/ -}}

{{- define "common.imagePullSecrets" -}}
{{- $root := index . 0 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- with (index . 1) | default $v.global.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{- /*
common.serviceAddress renders global.services.<name>, the address one app uses to reach another. The
defaults are the short Service names in one namespace; a site that splits namespaces or renames a release
overrides them once under global. It takes (list $root "<name>") and fails on an unknown name.
*/ -}}

{{- define "common.serviceAddress" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- if not (hasKey $v.global.services $name) -}}
{{- fail (printf "global.services has no %q" $name) -}}
{{- end -}}
{{- index $v.global.services $name -}}
{{- end -}}

{{- /*
An app that sets exposure.host is reachable on global.exposure.hosts.<exposure.host>. With global.mesh
kubernetes that is one Ingress per app, to the app's Service port exposure.port. The hosts and TLS are
global, so a site names each host once and every app that serves one picks it up.
*/ -}}

{{- /*
With global.networkPolicy.enabled, each app renders one NetworkPolicy selecting all of its release's pods
(by app.kubernetes.io/name; networkPolicy.podSelector, a full label selector, overrides that, for pods
another controller creates or an app with two workloads). It lists both Ingress and
Egress, so anything the rules below don't allow is denied for those pods:
  - ingress: the app's networkPolicy.ingress rules
  - egress: DNS, then the app's networkPolicy.egress rules
  - with global.mesh istio, also egress to istiod (15012, 15017) and ingress to the sidecar's own ports
Rules are NetworkPolicy rules as Kubernetes writes them, as a list or as a templated string (so a rule can
depend on values), and a node names its peers by app.kubernetes.io/name, which the Argo CD and the Helm
paths both set to the app's name.
*/ -}}

{{- define "common.networkPolicy.rules" -}}
{{- $root := index . 0 -}}
{{- $rules := index . 1 -}}
{{- if kindIs "string" $rules }}{{ tpl $rules $root | trim }}{{ else if $rules }}{{ tpl (toYaml $rules) $root | trim }}{{ end -}}
{{- end -}}

{{- /* cspell:words daemonset */ -}}

{{- define "common.vaultEnabled" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if $v.vault.enabled }}true{{ end -}}
{{- end -}}

{{- /* (list $root $workload): true when Vault is on and the pod declares any secretEnv. */ -}}

{{- define "common.vaultInjected" -}}
{{- $root := index . 0 -}}
{{- $d := index . 1 -}}
{{- if include "common.vaultEnabled" $root }}
{{- range $name, $c := $d.containers }}
{{- if and $c $c.secretEnv }}true{{ end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "common.secretFilePath" -}}
{{- $root := index . 0 -}}
{{- $s := index . 1 -}}
{{- $vault := default (dict) $s.vault -}}
{{- default (printf "/vault/secrets/%s-%s" (tpl $s.secret $root) $s.key) $vault.file -}}
{{- end -}}

{{- /* (list $root "<container>" "<NAME>"): the container is looked up in deployment, then daemonset. */ -}}

{{- define "common.secretFile" -}}
{{- $root := index . 0 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $c := index (default (dict) $v.deployment.containers) (index . 1) -}}
{{- if not (and $c (hasKey (default (dict) $c.secretEnv) (index . 2))) -}}
{{- $c = index (default (dict) $v.daemonset.containers) (index . 1) -}}
{{- end -}}
{{- $s := index (default (dict) (and $c $c.secretEnv)) (index . 2) -}}
{{- include "common.secretFilePath" (list $root (required (printf "common.secretFile: no secretEnv %s in container %s" (index . 2) (index . 1)) $s)) -}}
{{- end -}}

{{- define "common.vaultTemplate" -}}
{{- $path := index . 0 -}}
{{- $s := index . 1 -}}
{{- $vault := default (dict) $s.vault -}}
{{- $value := printf "index .Data.data %q" $s.key -}}
{{- if $vault.yamlKey -}}
{{- $keys := splitList "." $vault.yamlKey -}}
{{- $body := "" -}}
{{- range $i, $k := $keys -}}
{{- $body = printf "%s%s%s:" $body (repeat (int (mul $i 2)) " ") $k -}}
{{- if eq (add1 $i) (len $keys) -}}
{{- $body = printf "%s {{ %s | toJSON }}" $body $value -}}
{{- else -}}
{{- $body = printf "%s\n" $body -}}
{{- end -}}
{{- end -}}
{{- printf "{{- with secret %q -}}\n%s\n{{- end -}}" $path $body -}}
{{- else -}}
{{- printf "{{- with secret %q -}}{{ %s }}{{- end -}}" $path $value -}}
{{- end -}}
{{- end -}}

{{- /* (list $root $workload): the Vault Agent Injector annotations for one pod. */ -}}

{{- define "common.vaultAnnotations" -}}
{{- $root := index . 0 -}}
{{- $d := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $annotations := dict "vault.hashicorp.com/agent-inject" "true" "vault.hashicorp.com/role" (default (include "common.fullname" $root) $v.vault.role) -}}
{{- range $name, $c := $d.containers }}
{{- if $c }}
{{- range $envName, $s := $c.secretEnv }}
{{- if $s }}
{{- $file := include "common.secretFilePath" (list $root $s) -}}
{{- $path := printf "%s/%s" (trimSuffix "/" $v.vault.path) (tpl $s.secret $root) -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-secret-%s" (base $file)) $path -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-template-%s" (base $file)) (include "common.vaultTemplate" (list $path $s)) -}}
{{- if ne (dir $file) "/vault/secrets" }}
{{- $_ := set $annotations (printf "vault.hashicorp.com/secret-volume-path-%s" (base $file)) (dir $file) -}}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml (mustMergeOverwrite $annotations (default (dict) $v.vault.annotations)) -}}
{{- end -}}
