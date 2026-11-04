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
  {{- $env := mustMergeOverwrite (deepCopy (default (dict) $c.env)) (include "common.secretEnvMap" (list $root $c.secretEnv (printf "%s.containers.%s.secretEnv" $key $name)) | fromYaml) -}}
  {{- with $env }}
  env:
    {{- range $envName, $envValue := . }}
    {{- if include "common.entryEnabled" (list $root $envValue) }}
    - name: {{ $envName }}
      {{- if kindIs "map" $envValue }}
      {{- tpl (toYaml (omit $envValue "if")) $root | nindent 6 }}
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
  {{- $v := include "common.values" $root | fromYaml }}
  {{- range $probe := list "startupProbe" "livenessProbe" "readinessProbe" }}
  {{- with index $c $probe }}
  {{ $probe }}:
    {{- toYaml (mustMergeOverwrite (deepCopy (index $v.probes $probe | default dict)) (deepCopy .)) | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- /* global.resources, with the container's own resources over it key by key. */}}
  {{- with mustMergeOverwrite (deepCopy ($v.global.resources | default dict)) (deepCopy ($c.resources | default dict)) }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $workload := index $v $key }}
  {{- with mustMergeOverwrite (deepCopy ($workload.containerSecurityContext | default dict)) (deepCopy ($c.securityContext | default dict)) }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $mounts := default list $c.volumeMounts }}
  {{- if and $c.clickhouseCA (include "common.clickhouseExternal" $root) }}
  {{- $mounts = append $mounts (dict "name" "clickhouse-ca" "mountPath" "/etc/clickhouse-ca" "readOnly" true) }}
  {{- end }}
  {{- with $mounts }}
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
  {{- /* A container with clickhouseCA mounts the external ClickHouse's CA bundle (common.clickhouseCAVolume). */}}
  {{- $clickhouseCA := false }}
  {{- range $d.containers }}{{ if and . .clickhouseCA }}{{ $clickhouseCA = true }}{{ end }}{{ end }}
  {{- $clickhouseCA = and $clickhouseCA (include "common.clickhouseExternal" $root) }}
  {{- if or $d.volumes $clickhouseCA }}
  volumes:
    {{- range $name, $volume := $d.volumes }}
    {{- if $volume }}
    - name: {{ $name }}
      {{- tpl (ternary $volume (toYaml $volume) (kindIs "string" $volume)) $root | trim | nindent 6 }}
    {{- end }}
    {{- end }}
    {{- if $clickhouseCA }}
    - name: clickhouse-ca
      {{- include "common.clickhouseCAVolume" $root | nindent 6 }}
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
common.clickhouseEgress renders the NetworkPolicy egress rule an app uses to reach ClickHouse. It takes
(list $root (list <port>...)): the ports on the ClickHouse pods this stack runs, selected by
common.clickhousePodLabels. With global.clickhouse.external, ClickHouse is a service someone else runs:
the rule allows only the port of global.services.clickhouse, to global.clickhouse.networkPolicyPeers, or to any
destination when that is empty, and the in-cluster ports are dropped.
*/ -}}

{{- /*
common.clickhouseExternal is "true" with global.clickhouse.external and empty without. An external ClickHouse
is reached only over verified TLS, so it fails the render unless global.clickhouse.tls names the server's
certificate name and the ConfigMap with its CA bundle.
*/ -}}

{{- define "common.clickhouseExternal" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $c := $v.global.clickhouse -}}
{{- if $c.external -}}
{{- if not $c.tls.serverName -}}
{{- fail "global.clickhouse.external is true but global.clickhouse.tls.serverName is empty: name the certificate the service owner's ClickHouse presents (README: An external ClickHouse)" -}}
{{- end -}}
{{- if not $c.tls.caConfigMap -}}
{{- fail "global.clickhouse.external is true but global.clickhouse.tls.caConfigMap is empty: name the ConfigMap with the CA bundle the platform provides (README: An external ClickHouse)" -}}
{{- end -}}
{{- if not (include "common.serviceAddress" (list . "clickhouse") | regexMatch ":[0-9]+$") -}}
{{- fail "global.clickhouse.external is true but global.services.clickhouse is not host:port" -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{- /*
common.clickhouseStandalone is "true" with global.clickhouse.standalone and empty without: the clickhouse node
runs ClickHouse as a plain single-replica Deployment, with a PVC and a Service, instead of a ClickHouseInstallation,
so there is no operator and no CRD. It fails the render together with global.clickhouse.external, which says
there is no ClickHouse here at all.
*/ -}}

{{- define "common.clickhouseStandalone" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $c := $v.global.clickhouse -}}
{{- if $c.standalone -}}
{{- if $c.external -}}
{{- fail "global.clickhouse.standalone and global.clickhouse.external are both true: standalone runs ClickHouse in this namespace, external consumes a service owner's; set one" -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{- /*
common.clickhousePodLabels: the labels that select the ClickHouse server pods this stack runs, as a YAML map. The
operator labels its pods clickhouse.altinity.com/chi: otel; the standalone Deployment's pods carry
app.kubernetes.io/name: clickhouse.
*/ -}}

{{- define "common.clickhousePodLabels" -}}
{{- if include "common.clickhouseStandalone" . -}}
app.kubernetes.io/name: clickhouse
{{- else -}}
clickhouse.altinity.com/chi: otel
{{- end -}}
{{- end -}}

{{- /*
common.clickhouseCA: where a container finds the external ClickHouse's CA bundle, /etc/clickhouse-ca/<caKey>.
A container that sets clickhouseCA: true gets global.clickhouse.tls.caConfigMap mounted there, with
global.clickhouse.external only; common.clickhouseCAVolume is that volume's source, for a pod common does not
render (the clickhouse node's schema Job).
*/ -}}

{{- define "common.clickhouseCA" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- printf "/etc/clickhouse-ca/%s" $v.global.clickhouse.tls.caKey -}}
{{- end -}}

{{- define "common.clickhouseCAVolume" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if include "common.clickhouseExternal" . -}}
configMap:
  name: {{ $v.global.clickhouse.tls.caConfigMap }}
{{- else -}}
emptyDir: {}
{{- end -}}
{{- end -}}

{{- define "common.clickhouseEgress" -}}
{{- $root := index . 0 -}}
{{- $ports := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- if include "common.clickhouseExternal" $root -}}
{{- $port := include "common.serviceAddress" (list $root "clickhouse") | splitList ":" | last -}}
{{- with $v.global.clickhouse.networkPolicyPeers }}
- to:
    {{- toYaml . | nindent 4 }}
  ports:
{{- else }}
- ports:
{{- end }}
    - port: {{ int $port }}
      protocol: TCP
{{- else }}
- to:
    - podSelector:
        matchLabels:
          {{- include "common.clickhousePodLabels" $root | nindent 10 }}
  ports:
    {{- range $ports }}
    - port: {{ int . }}
      protocol: TCP
    {{- end }}
{{- end -}}
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
{{- if $c }}
{{- range $envName, $s := $c.secretEnv }}{{ if include "common.entryEnabled" (list $root $s) }}true{{ end }}{{ end }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- /*
(list $root $secretEnv $where): the env vars a secretEnv map renders, as a map of name to value. Vault off, each
entry is a secretKeyRef; Vault on, an entry with vault.env sets that variable to the injected file's path, and
any other entry renders nothing. $where names the map in a missing-key error.
*/ -}}

{{- define "common.secretEnvMap" -}}
{{- $root := index . 0 -}}
{{- $where := index . 2 -}}
{{- $vaultEnabled := include "common.vaultEnabled" $root -}}
{{- $env := dict -}}
{{- range $envName, $s := index . 1 }}
{{- if include "common.entryEnabled" (list $root $s) }}
{{- $secret := tpl (required (printf "%s.%s.secret is required" $where $envName) $s.secret) $root -}}
{{- $secretKey := required (printf "%s.%s.key is required" $where $envName) $s.key -}}
{{- if $vaultEnabled }}
{{- with (default (dict) $s.vault).env }}
{{- $_ := set $env . (include "common.secretFilePath" (list $root $s)) -}}
{{- end }}
{{- else }}
{{- $_ := set $env $envName (dict "valueFrom" (dict "secretKeyRef" (dict "name" $secret "key" $secretKey))) -}}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml $env -}}
{{- end -}}

{{- /*
The secretEnv delivery a Deployment's container gets, for a pod a node writes itself under objects (a Job or a
CronJob). Each takes (list $root $secretEnv), $secretEnv being a map in the secretEnv shape:

  common.secretEnv            the container's env list entries: a secretKeyRef per entry with Vault off, the
                              vault.env file paths with it on
  common.jobVaultAnnotations  the pod's Vault Agent Injector annotations, with agent-pre-populate-only so the
                              agent runs only as an init container and the Job's pod can complete; empty with
                              Vault off or no entry
  common.secretEnvExports     shell lines that export each entry's variable from its injected file, for an app
                              that reads its secret only from the environment; empty with Vault off

The pod sets automountServiceAccountToken to whether common.jobVaultAnnotations renders anything, because the
agent logs in with the pod's ServiceAccount token.
*/ -}}

{{- define "common.secretEnv" -}}
{{- $root := index . 0 -}}
{{- range $envName, $envValue := include "common.secretEnvMap" (list $root (index . 1) "secretEnv") | fromYaml }}
- name: {{ $envName }}
  {{- if kindIs "map" $envValue }}
  {{- toYaml $envValue | nindent 2 }}
  {{- else }}
  value: {{ $envValue | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "common.jobVaultAnnotations" -}}
{{- $root := index . 0 -}}
{{- $pod := dict "containers" (dict "job" (dict "secretEnv" (index . 1))) -}}
{{- if include "common.vaultInjected" (list $root $pod) -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $annotations := include "common.vaultAnnotations" (list $root $pod) | fromYaml -}}
{{- toYaml (mustMergeOverwrite $annotations (dict "vault.hashicorp.com/agent-pre-populate-only" "true") (default (dict) $v.vault.annotations)) -}}
{{- end -}}
{{- end -}}

{{- define "common.secretEnvExports" -}}
{{- $root := index . 0 -}}
{{- if include "common.vaultEnabled" $root }}
{{- range $envName, $s := index . 1 }}
{{- if include "common.entryEnabled" (list $root $s) }}
{{ $envName }}="$(cat {{ include "common.secretFilePath" (list $root $s) | squote }})"
export {{ $envName }}
{{- end }}
{{- end }}
{{- end }}
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

{{- /* (list $path $s $field): the agent template that writes field $field of record $path. */ -}}

{{- define "common.vaultTemplate" -}}
{{- $path := index . 0 -}}
{{- $s := index . 1 -}}
{{- $vault := default (dict) $s.vault -}}
{{- $value := printf "index .Data.data %q" (index . 2) -}}
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

{{- /*
(list $root $secretEnv): where Vault holds one secretEnv entry, as {path, field}. With vault.secret, every entry
is a field of that one record, named <Secret name>-<key> unless the entry sets vault.field; without it, each
Secret name is its own record and the field is the key.
*/ -}}

{{- define "common.vaultRecord" -}}
{{- $root := index . 0 -}}
{{- $s := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $secret := tpl $s.secret $root -}}
{{- $field := (default (dict) $s.vault).field -}}
{{- if $v.vault.secret -}}
path: {{ printf "%s/%s" (trimSuffix "/" $v.vault.path) $v.vault.secret | quote }}
field: {{ default (printf "%s-%s" $secret $s.key) $field | quote }}
{{- else -}}
path: {{ printf "%s/%s" (trimSuffix "/" $v.vault.path) $secret | quote }}
field: {{ default $s.key $field | quote }}
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
{{- if include "common.entryEnabled" (list $root $s) }}
{{- $file := include "common.secretFilePath" (list $root $s) -}}
{{- $record := include "common.vaultRecord" (list $root $s) | fromYaml -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-secret-%s" (base $file)) $record.path -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-template-%s" (base $file)) (include "common.vaultTemplate" (list $record.path $s $record.field)) -}}
{{- if ne (dir $file) "/vault/secrets" }}
{{- $_ := set $annotations (printf "vault.hashicorp.com/secret-volume-path-%s" (base $file)) (dir $file) -}}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml (mustMergeOverwrite $annotations (default (dict) $v.vault.annotations)) -}}
{{- end -}}

{{- /* "true" when the app renders a Service: service.enabled and at least one port. */ -}}

{{- define "common.serviceEnabled" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if and $v.service.enabled $v.service.ports }}true{{ end -}}
{{- end -}}

{{- /* "true" when the app renders a Deployment: deployment.enabled and at least one container. */ -}}

{{- define "common.deploymentEnabled" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if and $v.deployment.enabled $v.deployment.containers }}true{{ end -}}
{{- end -}}

{{- /*
(list $root $entry): "true" when an env or secretEnv entry is rendered. An entry is off when it is null, or when
it is a map whose "if" key, templated, renders empty or "false"; "if" is never rendered itself. A node turns an
entry on with the feature it belongs to, such as

  OTLP_BEARER_TOKEN:
    if: '{{ .Values.collector.auth.enabled }}'
    valueFrom: ...

so no environment has to delete it: Argo CD drops null values from an Application's valuesObject, so an
environment's null never reaches the chart.
*/ -}}

{{- define "common.entryEnabled" -}}
{{- $root := index . 0 -}}
{{- $e := index . 1 -}}
{{- if not (kindIs "invalid" $e) -}}
{{- if and (kindIs "map" $e) (hasKey $e "if") -}}
{{- $on := trim (tpl (toString (index $e "if")) $root) -}}
{{- if and $on (ne $on "false") }}true{{ end -}}
{{- else }}true{{ end -}}
{{- end -}}
{{- end -}}

{{- /* "true" when the mesh is istio in ambient mode: no sidecars, ztunnel carries traffic over HBONE. */ -}}

{{- define "common.istioAmbient" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $mode := toString (dig "istio" "dataplaneMode" "sidecar" $v.global) -}}
{{- if not (has $mode (list "sidecar" "ambient")) -}}
{{- fail (printf "global.istio.dataplaneMode must be sidecar or ambient, not %q" $mode) -}}
{{- end -}}
{{- if and (eq (include "common.mesh" .) "istio") (eq $mode "ambient") }}true{{ end -}}
{{- end -}}

{{- /* "true" when the mesh is istio with a sidecar in every pod. */ -}}

{{- define "common.istioSidecar" -}}
{{- if and (eq (include "common.mesh" .) "istio") (not (include "common.istioAmbient" .)) }}true{{ end -}}
{{- end -}}

{{- /*
(list $root $rulesYAML): under ambient, the HBONE copy of each rule whose peers are in the mesh. ztunnel sends a
pod's traffic to the destination pod on 15008, so a rule allowing pods or namespaces on their own ports also has
to allow 15008 between the same peers. A rule with no peers (any source or destination) gets 15008 from or to
anywhere; a rule whose peers are only ipBlocks is outside the mesh and gets no copy.
*/ -}}

{{- define "common.networkPolicy.hbone" -}}
{{- $rules := index . 1 -}}
{{- $field := index . 2 -}}
{{- $out := list -}}
{{- if $rules }}
{{- range $r := fromYamlArray $rules }}
{{- $peers := default list (index $r $field) -}}
{{- $mesh := list -}}
{{- range $p := $peers }}{{ if not $p.ipBlock }}{{ $mesh = append $mesh $p }}{{ end }}{{ end -}}
{{- $hbone := list (dict "port" 15008 "protocol" "TCP") -}}
{{- if not $peers }}
{{- $out = append $out (dict "ports" $hbone) -}}
{{- else if $mesh }}
{{- $out = append $out (dict $field $mesh "ports" $hbone) -}}
{{- end }}
{{- end }}
{{- end }}
{{- with $out }}{{ toYaml (uniq .) }}{{ end -}}
{{- end -}}

{{- /* (list $root "<signal>"): global.retention's days for traces, logs or metrics, defaults included. */ -}}

{{- define "common.retentionDays" -}}
{{- $v := include "common.values" (index . 0) | fromYaml -}}
{{- int (required (printf "global.retention.%s is required" (index . 1)) (index $v.global.retention (index . 1))) -}}
{{- end -}}

{{- /*
How exposure is rendered: global.exposure.api, or by default the mesh's own way (istio: an Istio Gateway and
VirtualService; kubernetes: an Ingress). gateway-api renders HTTPRoutes on the platform's Gateway API Gateway.
*/ -}}

{{- define "common.exposureApi" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $api := toString (dig "exposure" "api" "" $v.global) -}}
{{- if not $api -}}
{{- $api = ternary "istio" "ingress" (eq (include "common.mesh" .) "istio") -}}
{{- end -}}
{{- if not (has $api (list "istio" "gateway-api" "ingress")) -}}
{{- fail (printf "global.exposure.api must be istio, gateway-api or ingress, not %q" $api) -}}
{{- end -}}
{{- if and (eq $api "istio") (ne (include "common.mesh" .) "istio") -}}
{{- fail "global.exposure.api is istio but global.mesh is not: an Istio Gateway needs the mesh" -}}
{{- end -}}
{{- $api -}}
{{- end -}}
