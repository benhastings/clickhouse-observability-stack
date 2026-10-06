{{- define "common.podDisruptionBudget" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $p := $v.podDisruptionBudget -}}
{{- if and $v.deployment.enabled $p.enabled }}
{{- $hasMin := not (kindIs "invalid" $p.minAvailable) -}}
{{- $hasMax := not (kindIs "invalid" $p.maxUnavailable) -}}
{{- if and $hasMin $hasMax }}
{{- fail "podDisruptionBudget.minAvailable and podDisruptionBudget.maxUnavailable are mutually exclusive; set minAvailable to null to use maxUnavailable" }}
{{- end }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  {{- if $hasMin }}
  minAvailable: {{ $p.minAvailable }}
  {{- end }}
  {{- if $hasMax }}
  maxUnavailable: {{ $p.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" . | nindent 6 }}
{{- end }}
{{- end -}}

{{- define "common.autoscaling" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- $a := $v.autoscaling -}}
{{- if and $v.deployment.enabled $a.enabled }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  {{- include "common.metadata" (list . (include "common.fullname" .)) | nindent 2 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "common.fullname" . }}
  minReplicas: {{ $a.minReplicas }}
  maxReplicas: {{ $a.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ $a.targetCPUUtilizationPercentage }}
{{- end }}
{{- end -}}
