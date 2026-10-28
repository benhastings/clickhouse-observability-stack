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

{{/*
"true" when the stack may create cluster-scoped objects (clusterScoped, true by default), empty for the
restricted-namespace profile. That profile works only when nothing in it needs a cluster-scoped object, so the
render fails unless a platform team runs the ClickHouse operator (global.clickhouseOperator.shared) and every
enabled collector, the otel-collector node under any name, sets rbac.scope: namespace.
*/}}
{{- define "app-of-apps.clusterScoped" -}}
{{- if ne .Values.clusterScoped false -}}
true
{{- else -}}
{{- if not (dig "clickhouseOperator" "shared" false (default dict .Values.global)) -}}
{{- fail "clusterScoped is false but global.clickhouseOperator.shared is not true: the stack's own operator needs CRDs, a ClusterRole and a ClusterRoleBinding, so set global.clickhouseOperator.shared: true and use the platform's" -}}
{{- end -}}
{{- range $name, $app := .Values.applications -}}
{{- if and (include "app-of-apps.enabled" (list $ $name $app)) (or (eq $name "otel-collector") (eq (toString $app.path) "cluster-nodes/otel-collector")) -}}
{{- if ne (toString (dig "rbac" "scope" "" (default dict $app.values))) "namespace" -}}
{{- fail (printf "clusterScoped is false but applications.%s.values.rbac.scope is not namespace: the collector would render a ClusterRole and ClusterRoleBinding, so set it to namespace (README: Collector RBAC)" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
