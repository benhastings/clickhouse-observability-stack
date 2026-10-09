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
{{- print (include "common.configMaps" .) (include "common.secrets" .) | sha256sum -}}
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
