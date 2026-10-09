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
vault:
  enabled: false
  role: ""
  path: secret/data
  annotations: {}
objects: {}
{{- end -}}

{{- define "common.values" -}}
{{- $defaults := include "common.defaults" . | fromYaml -}}
{{- $values := mustMergeOverwrite (deepCopy $defaults) (deepCopy .Values.AsMap) -}}
{{- $vault := mustMergeOverwrite $defaults.vault (deepCopy (default (dict) $values.global.vault)) (deepCopy (default (dict) .Values.vault)) -}}
{{- $_ := set $values "vault" $vault -}}
{{- toYaml $values -}}
{{- end -}}
