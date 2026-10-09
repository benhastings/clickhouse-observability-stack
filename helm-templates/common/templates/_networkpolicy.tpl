{{- /*
With global.networkPolicy.enabled, each app renders one NetworkPolicy selecting all of its release's pods
(by app.kubernetes.io/name; networkPolicy.podSelector, a full label selector, overrides that, for pods
another controller creates or an app with two workloads). It lists both Ingress and
Egress, so anything the rules below don't allow is denied for those pods:
  - ingress: the app's networkPolicy.ingress rules
  - egress: DNS, then the app's networkPolicy.egress rules
  - with global.mesh istio, also egress to istiod (15012, 15017) and ingress to the sidecar's own ports
Rules are NetworkPolicy rules as Kubernetes writes them, as a list or as a templated string (so a rule can
depend on values), and a node names its peers by app.kubernetes.io/name, which the Argo CD and the Helm
paths both set to the app's name.
*/ -}}
{{- define "common.networkPolicy.rules" -}}
{{- $root := index . 0 -}}
{{- $rules := index . 1 -}}
{{- if kindIs "string" $rules }}{{ tpl $rules $root | trim }}{{ else if $rules }}{{ tpl (toYaml $rules) $root | trim }}{{ end -}}
{{- end -}}

{{- define "common.networkPolicy" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $np := $v.networkPolicy -}}
{{- if and $v.global.networkPolicy.enabled (ne $np.enabled false) }}
{{- $istio := eq (include "common.mesh" .) "istio" }}
{{- $ingress := include "common.networkPolicy.rules" (list . $np.ingress) }}
{{- $egress := include "common.networkPolicy.rules" (list . $np.egress) }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  podSelector:
    {{- if $np.podSelector }}
    {{- tpl (toYaml $np.podSelector) . | nindent 4 }}
    {{- else }}
    matchLabels:
      app.kubernetes.io/name: {{ include "common.fullname" . }}
    {{- end }}
  policyTypes:
    - Ingress
    - Egress
  {{- if or $ingress $istio }}
  ingress:
    {{- with $ingress }}
    {{- . | nindent 4 }}
    {{- end }}
    {{- if $istio }}
    # The sidecar's health and telemetry ports, which the mesh and kubelet reach.
    - ports:
        - port: 15020
          protocol: TCP
        - port: 15021
          protocol: TCP
        - port: 15090
          protocol: TCP
    {{- end }}
  {{- else }}
  ingress: []
  {{- end }}
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    {{- if $istio }}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ $v.global.networkPolicy.istioNamespace }}
      ports:
        - port: 15012
          protocol: TCP
        - port: 15017
          protocol: TCP
    {{- end }}
    {{- with $egress }}
    {{- . | nindent 4 }}
    {{- end }}
{{- end }}
{{- end -}}
