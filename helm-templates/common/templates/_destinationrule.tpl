{{- /*
With global.mesh istio, an app's Service gets a DestinationRule that sends traffic to it over Istio mutual
TLS. PeerAuthentication stays at the mesh default; requiring mTLS (STRICT) is the kind-with-Istio profile.
*/ -}}
{{- define "common.destinationRule" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if and $v.service.enabled (eq (include "common.mesh" .) "istio") }}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  host: {{ printf "%s.%s.svc.cluster.local" (include "common.fullname" .) (include "common.namespace" .) }}
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
{{- end }}
{{- end -}}
