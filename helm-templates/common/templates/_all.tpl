{{- /* cspell:words daemonset */ -}}
{{- define "common.all" -}}
{{- $_ := include "common.mesh" . -}}
{{ include "common.serviceAccount" . }}
{{ include "common.rbac" . }}
{{ include "common.configMaps" . }}
{{ include "common.secrets" . }}
{{ include "common.service" . }}
{{ include "common.ingress" . }}
{{ include "common.gateway" . }}
{{ include "common.deployment" . }}
{{ include "common.daemonset" . }}
{{ include "common.podDisruptionBudget" . }}
{{ include "common.autoscaling" . }}
{{ include "common.objects" . }}
{{- end -}}
