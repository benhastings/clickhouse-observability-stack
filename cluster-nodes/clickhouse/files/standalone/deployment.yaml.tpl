{{- /*
ClickHouse without the operator (global.clickhouse.standalone): one server as a Deployment, on the volume in
pvc.yaml.tpl, configured by config.yaml.tpl. Recreate, because the volume is ReadWriteOnce and a second pod could
not mount it. The server runs as the image's clickhouse user (101) with a read-only root filesystem, started
directly rather than through the image's entrypoint, which would write a default user into users.d.
*/}}
{{- $ch := .Values.clickhouse }}
{{- $v := include "common.values" . | fromYaml }}
{{- if gt (mul (int $ch.shards) (int $ch.replicas)) 1 }}
{{- fail "global.clickhouse.standalone runs one server: clickhouse.shards and clickhouse.replicas must be 1; more need the operator" }}
{{- end }}
{{- $server := tpl (.Files.Get "files/server.yaml.tpl") . | fromYaml }}
{{- $secretEnv := dict }}
{{- range $user, $u := $server.users }}
{{- $_ := set $secretEnv (printf "CLICKHOUSE_PASSWORD_%s" (upper $user)) (dict "secret" $u.secret "key" "password") }}
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "common.clickhousePodLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common.clickhousePodLabels" . | nindent 8 }}
      annotations:
        checksum/config: {{ tpl (.Files.Get "files/standalone/config.yaml.tpl") . | sha256sum }}
    spec:
      automountServiceAccountToken: false
      securityContext:
        {{- toYaml (mustMergeOverwrite (deepCopy $v.deployment.podSecurityContext) (dict "runAsUser" 101 "runAsGroup" 101 "fsGroup" 101)) | nindent 8 }}
      terminationGracePeriodSeconds: 60
      {{- with include "common.imagePullSecrets" (list $ list) | trim }}
      {{- . | nindent 6 }}
      {{- end }}
      containers:
        - name: clickhouse
          image: {{ include "common.image" (list $ $ch.image) | quote }}
          command:
            - /usr/bin/clickhouse-server
            - --config-file=/etc/clickhouse-server/config.xml
          ports:
            - name: http
              containerPort: 8123
              protocol: TCP
            - name: tcp
              containerPort: 9000
              protocol: TCP
            - name: metrics
              containerPort: 9363
              protocol: TCP
          env:
            {{- include "common.secretEnv" (list $ $secretEnv) | nindent 12 }}
          # Loading a large table's parts can take minutes after a restart: up to ten before the server is
          # given up on, and no liveness probe to restart it during a long merge.
          startupProbe:
            httpGet:
              path: /ping
              port: http
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            periodSeconds: 5
            timeoutSeconds: 5
          resources:
            {{- toYaml $ch.resources | nindent 12 }}
          securityContext:
            {{- toYaml $v.deployment.containerSecurityContext | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /var/lib/clickhouse
            - name: config
              mountPath: /etc/clickhouse-server/config.d
              readOnly: true
            - name: users
              mountPath: /etc/clickhouse-server/users.d
              readOnly: true
            - name: logs
              mountPath: /var/log/clickhouse-server
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "common.fullname" . }}-data
        - name: config
          configMap:
            name: {{ include "common.fullname" . }}-server
            items:
              {{- range $file, $_ := $server.files }}
              - key: {{ base $file }}
                path: {{ base $file }}
              {{- end }}
              - key: listen.xml
                path: listen.xml
        - name: users
          configMap:
            name: {{ include "common.fullname" . }}-server
            items:
              - key: users.xml
                path: otel.xml
        - name: logs
          emptyDir: {}
        - name: tmp
          emptyDir: {}
