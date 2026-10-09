{{- /*
With global.externalSecrets.enabled, every secrets.<key> that lists external.keys is materialized by the
External Secrets operator: an ExternalSecret whose target is the same Secret name the pods already read,
filled from <remotePath>/<Secret name> in the store global.externalSecrets.secretStoreRef names, one
property per key. The chart never renders the Secret itself in that mode and never installs the operator
or a store.
*/ -}}
{{- define "common.externalSecrets" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $x := $v.global.externalSecrets -}}
{{- if $x.enabled }}
{{- range $key, $secret := $v.secrets }}
{{- with ($secret | default dict).external }}
{{- if not $x.secretStoreRef.name }}
{{- fail "global.externalSecrets.enabled is true but global.externalSecrets.secretStoreRef.name is empty" }}
{{- end }}
{{- if not .keys }}
{{- fail (printf "secrets.%s.external.keys is empty" $key) }}
{{- end }}
{{- $name := include "common.resourceName" (list $ $key) }}
{{- $remote := .remoteKey | default (printf "%s/%s" (trimSuffix "/" $x.remotePath) $name | trimPrefix "/") }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  {{- include "common.metadata" (list $ $name) | nindent 2 }}
spec:
  refreshInterval: {{ $x.refreshInterval }}
  secretStoreRef:
    name: {{ $x.secretStoreRef.name }}
    kind: {{ $x.secretStoreRef.kind }}
  target:
    name: {{ $name }}
    creationPolicy: Owner
  data:
    {{- range .keys }}
    - secretKey: {{ . }}
      remoteRef:
        key: {{ $remote }}
        property: {{ . }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
