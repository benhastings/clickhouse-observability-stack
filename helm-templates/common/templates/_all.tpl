{{- define "common.all" -}}
{{ include "common.serviceAccount" . }}
{{ include "common.rbac" . }}
{{ include "common.configMaps" . }}
{{ include "common.secrets" . }}
{{ include "common.service" . }}
{{ include "common.deployment" . }}
{{ include "common.podDisruptionBudget" . }}
{{ include "common.autoscaling" . }}
{{ include "common.objects" . }}
{{- end -}}
