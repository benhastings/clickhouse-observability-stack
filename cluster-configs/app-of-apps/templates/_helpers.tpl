{{/* The Argo CD project every Application of this environment belongs to. */}}
{{- define "app-of-apps.project" -}}
{{- .Values.project | default (printf "observability-%s" .Values.environment) -}}
{{- end -}}
