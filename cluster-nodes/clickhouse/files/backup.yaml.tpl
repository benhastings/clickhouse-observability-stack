{{- $b := .Values.clickhouse.backup }}
{{- if not $b.enabled }}
{{- fail "objects.backup is set but clickhouse.backup.enabled is false; set both or neither" }}
{{- end }}
{{- if not $b.bucket }}
{{- fail "clickhouse.backup.bucket is required when clickhouse.backup.enabled is true" }}
{{- end }}
{{- $secret := printf "%s-backup" (include "common.fullname" .) }}
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
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          {{- with include "common.imagePullSecrets" (list $ list) | trim }}
          {{- . | nindent 10 }}
          {{- end }}
          containers:
            - name: clickhouse-backup
              image: {{ include "common.image" (list $ $b.image) | quote }}
              command:
                - /bin/clickhouse-backup
              args:
                - create_remote
              env:
                - name: CLICKHOUSE_HOST
                  value: clickhouse
                - name: CLICKHOUSE_PORT
                  value: "9000"
                - name: CLICKHOUSE_USERNAME
                  valueFrom:
                    secretKeyRef:
                      name: {{ include "common.fullname" . }}-credentials
                      key: username
                - name: CLICKHOUSE_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {{ include "common.fullname" . }}-credentials
                      key: password
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
                - name: S3_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: {{ $secret }}
                      key: access_key
                - name: S3_SECRET_KEY
                  valueFrom:
                    secretKeyRef:
                      name: {{ $secret }}
                      key: secret_key
              resources:
                {{- toYaml $b.resources | nindent 16 }}
