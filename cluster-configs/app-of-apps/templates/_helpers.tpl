{{/* The Argo CD project every Application of this environment belongs to. */}}
{{- define "app-of-apps.project" -}}
{{- .Values.project | default (printf "observability-%s" .Values.environment) -}}
{{- end -}}

{{/*
"true" when the application renders, empty when it does not: (list $ name app). An application is off with
enabled: false, and the clickhouse-operator application is also off when global.clickhouseOperator.shared says
a platform team already runs the operator; setting it enabled: true as well fails the render, since the two
operators would fight over the same installations.
*/}}
{{- define "app-of-apps.enabled" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $app := index . 2 -}}
{{- $shared := dig "clickhouseOperator" "shared" false (default dict $root.Values.global) -}}
{{- if and $app (ne $app.enabled false) -}}
{{- if and (eq $name "clickhouse-operator") $shared -}}
{{- if eq $app.enabled true -}}
{{- fail "applications.clickhouse-operator.enabled is true but global.clickhouseOperator.shared is true: a platform team already runs the operator, so remove enabled: true" -}}
{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
{{- end -}}
