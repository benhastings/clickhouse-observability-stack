{{- /*
An app that sets exposure.host is reachable on global.exposure.hosts.<exposure.host>. With global.mesh
kubernetes that is one Ingress per app, to the app's Service port exposure.port. The hosts and TLS are
global, so a site names each host once and every app that serves one picks it up.
*/ -}}
{{- define "common.ingress" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $x := $v.global.exposure -}}
{{- $key := $v.exposure.host -}}
{{- if and $x.enabled $key (eq (include "common.mesh" .) "kubernetes") }}
{{- $host := index ($x.hosts | default dict) $key | default "" -}}
{{- if not $host }}
{{- fail (printf "global.exposure.enabled is true but global.exposure.hosts.%s is empty" $key) }}
{{- end }}
{{- if not $v.service.enabled }}
{{- fail (printf "exposure.host is %s but service.enabled is false, so there is nothing to route to" $key) }}
{{- end }}
{{- $port := $v.exposure.port -}}
{{- if not (hasKey $v.service.ports $port) }}
{{- fail (printf "exposure.port %q is not one of service.ports" $port) }}
{{- end }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
  {{- with $v.exposure.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $x.ingressClassName }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with $x.tls.credentialName }}
  tls:
    - hosts:
        - {{ $host }}
      secretName: {{ . }}
  {{- end }}
  rules:
    - host: {{ $host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "common.fullname" . }}
                port:
                  name: {{ $port }}
{{- end }}
{{- end -}}
