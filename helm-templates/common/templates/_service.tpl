{{- define "common.service" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $s := $v.service -}}
{{- if $s.enabled }}
---
apiVersion: v1
kind: Service
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
  {{- with $s.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $s.type }}
  selector:
    {{- include "common.selectorLabels" . | nindent 4 }}
  ports:
    {{- if not $s.ports }}
    {{- fail "service.enabled is true but service.ports is empty" }}
    {{- end }}
    {{- range $name, $port := $s.ports }}
    {{- if $port }}
    - name: {{ $name }}
      port: {{ $port.port }}
      targetPort: {{ $port.targetPort | default $name }}
      protocol: {{ $port.protocol | default "TCP" }}
      {{- with $port.appProtocol }}
      appProtocol: {{ . }}
      {{- end }}
    {{- end }}
    {{- end }}
{{- end }}
{{- end -}}
