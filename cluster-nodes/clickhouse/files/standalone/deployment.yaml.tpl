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
{{- /*
With vault.enabled the passwords are files the Vault agent writes before the server starts (pre-populate only, as
for the Jobs: the server reads them once, so a rotation is a restart), and a shell exports each as the variable
users.d reads with from_env, then execs the server. Without it they are secretKeyRefs on the same variables.
*/}}
{{- $tlsVault := include "common.clickhouseTLSVault" . }}
{{- $agent := $secretEnv }}
{{- if $tlsVault }}
{{- /* global.clickhouse.tls.vault: the agent writes the certificate and key too, which config.yaml.tpl points at. */}}
{{- $serverTLS := (include "common.values" . | fromYaml).global.clickhouse.tls.serverSecret }}
{{- $agent = merge (dict "TLS_CERTIFICATE" (dict "secret" $serverTLS "key" "tls.crt") "TLS_KEY" (dict "secret" $serverTLS "key" "tls.key")) $secretEnv }}
{{- end }}
{{- $vault := include "common.jobVaultAnnotations" (list $ $agent) }}
{{- /*
TLS only (config.yaml.tpl): every client verifies the server against global.clickhouse.tls, which
common.clickhouseTLS checks, and the server's certificate and key are global.clickhouse.tls.serverSecret: a
kubernetes.io/tls Secret the platform provides, mounted here, or with global.clickhouse.tls.vault the same names read
as Vault records, written by the Vault agent. The tenant never issues a certificate.
*/}}
{{- $_ := include "common.clickhouseTLS" . }}
{{- $serverSecret := $v.global.clickhouse.tls.serverSecret }}
{{- if not $serverSecret }}
{{- fail "global.clickhouse.standalone is true but global.clickhouse.tls.serverSecret is empty: name the kubernetes.io/tls Secret with the server's certificate and key, which the platform provides (README: A standalone ClickHouse)" }}
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
        {{- with $vault }}
        {{- . | nindent 8 }}
        {{- end }}
    spec:
      # The Vault agent logs in with the pod's ServiceAccount token.
      automountServiceAccountToken: {{ ne $vault "" }}
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
            {{- if $vault }}
            - /bin/sh
            - -c
            - |
              # A missing file or an empty field stops the server rather than start a user with no password.
              set -eu
              {{- include "common.secretEnvExports" (list $ $secretEnv) | trim | nindent 14 }}
              {{- range $envName, $_ := $secretEnv }}
              : "${{ "{" }}{{ $envName }}:?is empty in Vault}"
              {{- end }}
              exec /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
            {{- else }}
            - /usr/bin/clickhouse-server
            - --config-file=/etc/clickhouse-server/config.xml
            {{- end }}
          # Named tcp-* so Istio passes the server's own TLS through as opaque TCP, inside its mTLS.
          ports:
            - name: tcp-https
              containerPort: 8443
              protocol: TCP
            - name: tcp-native
              containerPort: 9440
              protocol: TCP
            - name: http-metrics
              containerPort: 9363
              protocol: TCP
          {{- with include "common.secretEnv" (list $ $secretEnv) | trim }}
          env:
            {{- . | nindent 12 }}
          {{- end }}
          # Loading a large table's parts can take minutes after a restart: up to ten before the server is
          # given up on, and no liveness probe to restart it during a long merge.
          startupProbe:
            httpGet:
              path: /ping
              port: tcp-https
              scheme: HTTPS
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /ping
              port: tcp-https
              scheme: HTTPS
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
            {{- if not $tlsVault }}
            - name: tls
              mountPath: /etc/clickhouse-server/tls
              readOnly: true
            {{- end }}
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
        {{- if not $tlsVault }}
        - name: tls
          secret:
            secretName: {{ $serverSecret }}
            defaultMode: 0440
            items:
              - key: tls.crt
                path: tls.crt
              - key: tls.key
                path: tls.key
        {{- end }}
