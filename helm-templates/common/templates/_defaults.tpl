{{- /* cspell:words daemonset */ -}}
{{- define "common.defaults" -}}
nameOverride: ""
global:
  mesh: istio
  namespace: ""
  labels: {}
  exposure:
    enabled: false
    hosts: {}
    ingressClassName: ""
    tls:
      credentialName: ""
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
daemonset:
  enabled: false
  updateStrategy:
    type: RollingUpdate
  selectorLabels: {}
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
podDisruptionBudget:
  enabled: false
  minAvailable: 1
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
service:
  enabled: false
  type: ClusterIP
  annotations: {}
  ports: {}
exposure:
  host: ""
  port: ""
  annotations: {}
configMaps: {}
secrets: {}
objects: {}
{{- end -}}

{{- define "common.values" -}}
{{- $defaults := include "common.defaults" . | fromYaml -}}
{{- toYaml (mustMergeOverwrite $defaults (deepCopy .Values.AsMap)) -}}
{{- end -}}
