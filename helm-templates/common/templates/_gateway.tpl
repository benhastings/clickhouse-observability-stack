{{- /*
With global.mesh istio, an app that sets exposure.host is reachable through Istio: a VirtualService routes
global.exposure.hosts.<exposure.host> to the app's Service port exposure.port. Each app renders its own
Gateway for its own host, so no app owns another's, unless global.exposure.gateway.name names a Gateway the
site already runs, in which case the VirtualService binds to that and no Gateway is rendered.
*/ -}}
{{- define "common.gateway" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $x := $v.global.exposure -}}
{{- $key := $v.exposure.host -}}
{{- if and $x.enabled $key (eq (include "common.mesh" .) "istio") }}
{{- $host := index ($x.hosts | default dict) $key | default "" -}}
{{- if not $host }}
{{- fail (printf "global.exposure.enabled is true but global.exposure.hosts.%s is empty" $key) }}
{{- end }}
{{- if not $v.service.enabled }}
{{- fail (printf "exposure.host is %s but service.enabled is false, so there is nothing to route to" $key) }}
{{- end }}
{{- $portName := $v.exposure.port -}}
{{- $port := index $v.service.ports $portName | default dict -}}
{{- if not $port.port }}
{{- fail (printf "exposure.port %q is not one of service.ports" $portName) }}
{{- end }}
{{- $gw := $x.gateway | default dict -}}
{{- $namespace := include "common.namespace" . -}}
{{- $gatewayRef := printf "%s/%s" $namespace (include "common.fullname" .) -}}
{{- if $gw.name }}
{{- $gatewayRef = printf "%s/%s" ($gw.namespace | default $namespace) $gw.name -}}
{{- else }}
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  selector:
    {{- toYaml ($gw.selector | default (dict "istio" "ingressgateway")) | nindent 4 }}
  servers:
    {{- with $x.tls.credentialName }}
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: {{ . }}
      hosts:
        - {{ $host }}
    {{- else }}
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - {{ $host }}
    {{- end }}
{{- end }}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  hosts:
    - {{ $host }}
  gateways:
    - {{ $gatewayRef }}
  http:
    - route:
        - destination:
            host: {{ printf "%s.%s.svc.cluster.local" (include "common.fullname" .) $namespace }}
            port:
              number: {{ $port.port }}
{{- end }}
{{- end -}}
