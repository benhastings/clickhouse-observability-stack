{{- $b := .Values.clickhouse.backup }}
{{- if include "common.clickhouseExternal" . }}
{{- fail "clickhouse.backup is on but global.clickhouse.external is true: backups of an external ClickHouse are the service owner's" }}
{{- end }}
{{- if not $b.enabled }}
{{- fail "objects.backup is set but clickhouse.backup.enabled is false; set both or neither" }}
{{- end }}
{{- if not $b.bucket }}
{{- fail "clickhouse.backup.bucket is required when clickhouse.backup.enabled is true" }}
{{- end }}
{{- $vault := include "common.jobVaultAnnotations" (list $ $b.secretEnv) }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "common.fullname" . }}-backup
spec:
  schedule: {{ $b.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata:
          labels:
            app.kubernetes.io/name: clickhouse-backup
          {{- with $vault }}
          annotations:
            {{- . | nindent 12 }}
          {{- end }}
        spec:
          restartPolicy: Never
          # The Vault agent logs in with the pod's ServiceAccount token.
          automountServiceAccountToken: {{ ne $vault "" }}
          {{- with include "common.imagePullSecrets" (list $ list) | trim }}
          {{- . | nindent 10 }}
          {{- end }}
          containers:
            - name: clickhouse-backup
              image: {{ include "common.image" (list $ $b.image) | quote }}
              command:
                {{- with include "common.secretEnvExports" (list $ $b.secretEnv) | trim }}
                # clickhouse-backup reads its credentials only from the environment, so a shell exports them from
                # the Vault agent's files first. The arguments stay clickhouse-backup's, as the restore steps expect.
                - /bin/sh
                - -c
                - |
                  {{- . | nindent 18 }}
                  exec /bin/clickhouse-backup "$@"
                - clickhouse-backup
                {{- else }}
                - /bin/clickhouse-backup
                {{- end }}
              args:
                - create_remote
              env:
                - name: CLICKHOUSE_HOST
                  value: clickhouse
                - name: CLICKHOUSE_PORT
                  value: "9000"
                - name: CLICKHOUSE_USERNAME
                  value: otel_admin
                {{- with include "common.secretEnv" (list $ $b.secretEnv) }}
                {{- . | nindent 16 }}
                {{- end }}
                - name: CLICKHOUSE_USE_EMBEDDED_BACKUP_RESTORE
                  value: "true"
                - name: REMOTE_STORAGE
                  value: s3
                - name: BACKUPS_TO_KEEP_LOCAL
                  value: "-1"
                - name: BACKUPS_TO_KEEP_REMOTE
                  value: {{ $b.keep | int | toString | quote }}
                - name: S3_BUCKET
                  value: {{ $b.bucket | quote }}
                - name: S3_PATH
                  value: {{ $b.path | quote }}
                - name: S3_ENDPOINT
                  value: {{ $b.endpoint | quote }}
                - name: S3_REGION
                  value: {{ $b.region | quote }}
                - name: S3_FORCE_PATH_STYLE
                  value: {{ $b.forcePathStyle | toString | quote }}
              resources:
                {{- toYaml $b.resources | nindent 16 }}
