{{- define "common.defaults" -}}
nameOverride: ""
global:
  namespace: ""
  labels: {}
serviceAccount:
  create: true
  name: ""
  automountToken: false
  annotations: {}
rbac:
  clusterRules: []
  rules: []
deployment:
  enabled: false
  replicas: 1
  strategy:
    type: RollingUpdate
  podLabels: {}
  podAnnotations: {}
  podSecurityContext: {}
  terminationGracePeriodSeconds: 30
  nodeSelector: {}
  affinity: {}
  tolerations: []
  topologySpreadConstraints: []
  priorityClassName: ""
  runtimeClassName: ""
  imagePullSecrets: []
  containers: {}
  volumes: {}
service:
  enabled: false
  type: ClusterIP
  annotations: {}
  ports: {}
configMaps: {}
secrets: {}
objects: {}
{{- end -}}

{{- define "common.values" -}}
{{- $defaults := include "common.defaults" . | fromYaml -}}
{{- toYaml (mustMergeOverwrite $defaults (deepCopy .Values.AsMap)) -}}
{{- end -}}
