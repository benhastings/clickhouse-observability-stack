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

{{- define "common.configMaps" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- range $key, $cm := $v.configMaps }}
{{- if $cm }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  {{- include "common.metadata" (list $ (include "common.resourceName" (list $ $key))) | nindent 2 }}
{{- if or $cm.data $cm.files }}
data:
  {{- with $cm.files }}
  {{- ($.Files.Glob .).AsConfig | nindent 2 }}
  {{- end }}
  {{- with $cm.data }}
  {{- include "common.dataEntries" (list $ .) | trim | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "common.secrets" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- range $key, $secret := $v.secrets }}
{{- if and $secret (ne $secret.create false) }}
---
apiVersion: v1
kind: Secret
metadata:
  {{- include "common.metadata" (list $ (include "common.resourceName" (list $ $key))) | nindent 2 }}
type: {{ $secret.type | default "Opaque" }}
{{- with $secret.stringData }}
stringData:
  {{- include "common.dataEntries" (list $ .) | trim | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "common.objects" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- range $key, $object := $v.objects }}
{{- if $object }}
{{- $rendered := tpl (toYaml $object) $ | fromYaml -}}
{{- if $rendered }}
{{- $metadata := default dict $rendered.metadata -}}
{{- $_ := set $metadata "name" (default (include "common.resourceName" (list $ $key)) $metadata.name) -}}
{{- if not (hasKey $metadata "namespace") }}
{{- $_ := set $metadata "namespace" (include "common.namespace" $) -}}
{{- end }}
{{- $_ := set $metadata "labels" (mustMergeOverwrite (include "common.labels" $ | fromYaml) (default dict $metadata.labels)) -}}
{{- $_ := set $rendered "metadata" $metadata }}
---
{{ toYaml $rendered }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
