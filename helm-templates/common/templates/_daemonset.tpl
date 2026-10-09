{{- /* cspell:words daemonset */ -}}
{{- define "common.daemonsetSelectorLabels" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- toYaml (mustMergeOverwrite (include "common.selectorLabels" . | fromYaml) $v.daemonset.selectorLabels) -}}
{{- end -}}

{{- define "common.daemonset" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $d := $v.daemonset -}}
{{- if $d.enabled }}
{{- $selector := include "common.daemonsetSelectorLabels" . -}}
{{- if and $v.deployment.enabled (eq $selector (include "common.selectorLabels" . | fromYaml | toYaml)) }}
{{- fail "deployment.enabled and daemonset.enabled are both true with the same selector labels, so one selector would match both kinds' pods; set daemonset.selectorLabels to tell them apart" }}
{{- end }}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
  {{- if $d.reloader }}
  annotations:
    reloader.stakater.com/auto: "true"
  {{- end }}
spec:
  {{- with $d.updateStrategy }}
  updateStrategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- $selector | nindent 6 }}
  template:
    {{- include "common.podTemplate" (list . "daemonset" $d $selector) | nindent 4 }}
{{- end }}
{{- end -}}
