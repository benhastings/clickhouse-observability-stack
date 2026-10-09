{{- $ch := .Values.clickhouse }}
{{- $s := $ch.schema }}
{{- $address := splitList ":" (include "common.serviceAddress" (list $ "clickhouse")) }}
{{- $sql := tpl (.Files.Get "files/schema.sql.tpl") . }}
apiVersion: batch/v1
kind: Job
metadata:
  # Named for the SQL it applies, so a change to files/schema.sql.tpl or to the TTLs is a new Job that
  # runs again, and Argo CD and Helm delete the old one.
  name: {{ include "common.fullname" . }}-schema-{{ $sql | sha256sum | trunc 8 }}
  labels:
    app.kubernetes.io/name: clickhouse-schema
  annotations:
    # After the installation is Completed, so the Job doesn't spend its retries on a server that isn't up.
    argocd.argoproj.io/sync-wave: "1"
spec:
  backoffLimit: {{ int $s.backoffLimit }}
  activeDeadlineSeconds: {{ int $s.activeDeadlineSeconds }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clickhouse-schema
      {{- if eq (include "common.mesh" $) "istio" }}
      # A native sidecar stops when the Job's container exits; a classic one would keep the pod running.
      annotations:
        sidecar.istio.io/nativeSidecar: "true"
      {{- end }}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      {{- with include "common.imagePullSecrets" (list $ list) | trim }}
      {{- . | nindent 6 }}
      {{- end }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: clickhouse-schema
          # The server image, for the clickhouse-client that matches it.
          image: {{ include "common.image" (list $ $ch.image) | quote }}
          command:
            - /bin/sh
            - -c
            - |
              until clickhouse-client --query 'SELECT 1' >/dev/null; do
                echo "waiting for ClickHouse at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT"
                sleep 5
              done
              exec clickhouse-client --multiquery --queries-file /schema/schema.sql
          env:
            - name: CLICKHOUSE_HOST
              value: {{ first $address | quote }}
            - name: CLICKHOUSE_PORT
              value: {{ last $address | quote }}
            - name: CLICKHOUSE_USER
              value: otel_admin
            - name: CLICKHOUSE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "common.fullname" . }}-admin
                  key: password
            - name: HOME
              value: /tmp
          volumeMounts:
            - name: schema
              mountPath: /schema
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            {{- toYaml $s.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            privileged: false
            readOnlyRootFilesystem: true
      volumes:
        - name: schema
          configMap:
            name: {{ include "common.fullname" . }}-schema
        - name: tmp
          emptyDir: {}
