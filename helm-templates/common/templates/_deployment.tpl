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
  {{- with $c.securityContext }}
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

{{- define "common.deployment" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $d := $v.deployment -}}
{{- if $d.enabled }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
  {{- if $d.reloader }}
  annotations:
    reloader.stakater.com/auto: "true"
  {{- end }}
spec:
  {{- if $v.autoscaling.enabled }}
  {{- $default := (include "common.defaults" . | fromYaml).deployment.replicas }}
  {{- if ne (int $d.replicas) (int $default) }}
  {{- fail (printf "autoscaling.enabled is true, so the HorizontalPodAutoscaler owns the replica count; remove deployment.replicas (%v) and set autoscaling.minReplicas instead" $d.replicas) }}
  {{- end }}
  {{- else }}
  replicas: {{ $d.replicas }}
  {{- end }}
  {{- with $d.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" . | nindent 6 }}
  template:
    {{- include "common.podTemplate" (list . "deployment" $d (include "common.selectorLabels" .)) | nindent 4 }}
{{- end }}
{{- end -}}
