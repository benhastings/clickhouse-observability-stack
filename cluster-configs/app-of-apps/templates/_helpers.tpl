{{/* The Argo CD project every Application of this environment belongs to. */}}
{{- define "app-of-apps.project" -}}
{{- .Values.project | default (printf "observability-%s" .Values.environment) -}}
{{- end -}}

{{/*
"true" when the application renders, empty when it does not: (list $ name app). An application is off with
enabled: false, and the clickhouse-operator application is also off when global.clickhouseOperator.shared says
a platform team already runs the operator, global.clickhouse.external that a service owner runs ClickHouse
itself, or global.clickhouse.standalone that the clickhouse node runs it without an operator; setting it
enabled: true as well fails the render.
*/}}
{{- define "app-of-apps.enabled" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $app := index . 2 -}}
{{- $shared := dig "clickhouseOperator" "shared" false (default dict $root.Values.global) -}}
{{- $external := dig "clickhouse" "external" false (default dict $root.Values.global) -}}
{{- $standalone := dig "clickhouse" "standalone" false (default dict $root.Values.global) -}}
{{- if and $app (ne $app.enabled false) -}}
{{- if and (eq $name "clickhouse-operator") (or $shared $external $standalone) -}}
{{- if eq $app.enabled true -}}
{{- $why := "global.clickhouseOperator.shared is true" -}}
{{- if $external }}{{ $why = "global.clickhouse.external is true" }}{{ else if $standalone }}{{ $why = "global.clickhouse.standalone is true" }}{{ end -}}
{{- fail (printf "applications.clickhouse-operator.enabled is true but %s: no operator of the stack's own may run, so remove enabled: true" $why) -}}
{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
"true" when the stack may create cluster-scoped objects (clusterScoped, true by default), empty for the
restricted-namespace profile. That profile works only when nothing in it needs a cluster-scoped object, so the
render fails unless ClickHouse is external (global.clickhouse.external), runs without an operator
(global.clickhouse.standalone), or a platform team runs the ClickHouse operator (global.clickhouseOperator.shared),
and every enabled collector, the otel-collector node under any
name, sets rbac.scope: namespace.
*/}}
{{- define "app-of-apps.clusterScoped" -}}
{{- if ne .Values.clusterScoped false -}}
true
{{- else -}}
{{- $global := default dict .Values.global -}}
{{- if not (or (dig "clickhouse" "external" false $global) (dig "clickhouse" "standalone" false $global) (dig "clickhouseOperator" "shared" false $global)) -}}
{{- fail "clusterScoped is false but none of global.clickhouse.external, global.clickhouse.standalone and global.clickhouseOperator.shared is true: the stack's own operator needs CRDs, a ClusterRole and a ClusterRoleBinding, so consume an external ClickHouse, run ClickHouse standalone, or use the platform's operator" -}}
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

{{/*
The secret mechanism one application's credentials come from, with the values its Application passes:
(list $root $app). vault when vault.enabled (the app's own, else global.vault.enabled), externalSecrets when
global.externalSecrets.enabled, otherwise kubernetes, Secrets pre-created in the namespace. Both on fails the
render, as common does for every node: each credential would have two producers.
*/}}
{{- define "app-of-apps.secretMechanism" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $app := index . 2 -}}
{{- $values := mustMergeOverwrite (dict "global" (deepCopy (default dict $root.Values.global))) (deepCopy (default dict $app.values)) -}}
{{- $vault := dig "vault" "enabled" (dig "global" "vault" "enabled" false $values) $values -}}
{{- $external := dig "global" "externalSecrets" "enabled" false $values -}}
{{- if and $vault $external -}}
{{- fail (printf "applications.%s: vault.enabled and global.externalSecrets.enabled are both true, so its credentials would have two producers; choose one secret mechanism for the environment (README: Credentials)" $name) -}}
{{- end -}}
{{- if $vault }}vault{{ else if $external }}externalSecrets{{ else }}kubernetes{{ end -}}
{{- end -}}

{{/*
Renders nothing; fails the render unless ClickHouse and every enabled client of its credentials read them
through the same mechanism: the clickhouse node (the server and the schema Job), cerberus, otel-collector, garmr
and garmr-sql-adapter, under their own names or another name with the same path. One of them on Vault while
another waits for a Kubernetes Secret would leave half the stack without a password.
*/}}
{{- define "app-of-apps.clickhouseSecrets" -}}
{{- $set := list "clickhouse" "cerberus" "otel-collector" "garmr" "garmr-sql-adapter" -}}
{{- $by := dict -}}
{{- range $name, $app := .Values.applications -}}
{{- if include "app-of-apps.enabled" (list $ $name $app) -}}
{{- $node := ternary (trimPrefix "cluster-nodes/" (toString $app.path)) $name (hasPrefix "cluster-nodes/" (toString $app.path)) -}}
{{- if has $node $set -}}
{{- $_ := set $by $name (include "app-of-apps.secretMechanism" (list $ $name $app)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if gt (len (uniq (values $by))) 1 -}}
{{- $each := list -}}
{{- range $name := keys $by | sortAlpha -}}
{{- $each = append $each (printf "%s: %s" $name (get $by $name)) -}}
{{- end -}}
{{- fail (printf "ClickHouse's credentials must come from one secret mechanism, but the applications that read them disagree (%s); set the same vault.enabled and global.externalSecrets.enabled for all of them (README: Credentials)" (join ", " $each)) -}}
{{- end -}}
{{- end -}}
