{{- define "common.container" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $c := index . 2 -}}
- name: {{ $name }}
  image: "{{ required (printf "deployment.containers.%s.image.repository is required" $name) $c.image.repository }}:{{ required (printf "deployment.containers.%s.image.tag is required" $name) $c.image.tag }}"
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
  {{- with $c.env }}
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

{{- define "common.deployment" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $d := $v.deployment -}}
{{- if $d.enabled }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  replicas: {{ $d.replicas }}
  {{- with $d.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common.selectorLabels" . | nindent 8 }}
        {{- with $d.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        checksum/config: {{ include "common.configChecksum" . }}
        {{- with $d.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "common.serviceAccountName" . }}
      automountServiceAccountToken: {{ $v.serviceAccount.automountToken }}
      {{- with $d.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $d.terminationGracePeriodSeconds }}
      containers:
        {{- if not $d.containers }}
        {{- fail "deployment.enabled is true but deployment.containers is empty" }}
        {{- end }}
        {{- range $name, $c := $d.containers }}
        {{- if $c }}
        {{- include "common.container" (list $ $name $c) | nindent 8 }}
        {{- end }}
        {{- end }}
      {{- with $d.volumes }}
      volumes:
        {{- range $name, $volume := . }}
        {{- if $volume }}
        - name: {{ $name }}
          {{- tpl (toYaml $volume) $ | nindent 10 }}
        {{- end }}
        {{- end }}
      {{- end }}
{{- end }}
{{- end -}}
