{{- define "common.rbac" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $name := include "common.fullname" . -}}
{{- with $v.rbac.clusterRules }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  {{- include "common.clusterMetadata" (list $ $name) | nindent 2 }}
rules:
  {{- toYaml . | nindent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  {{- include "common.clusterMetadata" (list $ $name) | nindent 2 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $name }}
subjects:
  - kind: ServiceAccount
    name: {{ include "common.serviceAccountName" $ }}
    namespace: {{ include "common.namespace" $ }}
{{- end }}
{{- with $v.rbac.rules }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  {{- include "common.metadata" (list $ $name) | nindent 2 }}
rules:
  {{- toYaml . | nindent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  {{- include "common.metadata" (list $ $name) | nindent 2 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $name }}
subjects:
  - kind: ServiceAccount
    name: {{ include "common.serviceAccountName" $ }}
    namespace: {{ include "common.namespace" $ }}
{{- end }}
{{- end -}}
