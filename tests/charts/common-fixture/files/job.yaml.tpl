{{- /* A Job a node writes itself under objects, its secrets delivered by the secretEnv helpers. */}}
{{- $vault := include "common.jobVaultAnnotations" (list $ .Values.job.secretEnv) }}
apiVersion: batch/v1
kind: Job
spec:
  template:
    metadata:
      {{- with $vault }}
      annotations:
        {{- . | nindent 8 }}
      {{- end }}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: {{ ne $vault "" }}
      containers:
        - name: job
          image: example/job:1.0.0
          command:
            - /bin/sh
            - -c
            - |
              {{- with include "common.secretEnvExports" (list $ .Values.job.secretEnv) | trim }}
              {{- . | nindent 14 }}
              {{- end }}
              exec /bin/job
          env:
            - name: MODE
              value: once
            {{- with include "common.secretEnv" (list $ .Values.job.secretEnv) }}
            {{- . | nindent 12 }}
            {{- end }}
          resources:
            limits:
              memory: 32Mi
