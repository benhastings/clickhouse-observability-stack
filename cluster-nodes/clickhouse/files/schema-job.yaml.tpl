{{- $ch := .Values.clickhouse }}
{{- $s := $ch.schema }}
{{- $address := splitList ":" (include "common.serviceAddress" (list $ "clickhouse")) }}
{{- $sql := tpl (.Files.Get "files/schema.sql.tpl") . }}
{{- $external := include "common.clickhouseExternal" . }}
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
      {{- $vault := include "common.jobVaultAnnotations" (list $ $s.secretEnv) }}
      {{- if or $vault (include "common.istioSidecar" $) }}
      annotations:
        {{- if include "common.istioSidecar" $ }}
        # A native sidecar stops when the Job's container exits; a classic one would keep the pod running.
        sidecar.istio.io/nativeSidecar: "true"
        {{- end }}
        {{- with $vault }}
        {{- . | nindent 8 }}
        {{- end }}
      {{- end }}
    spec:
      restartPolicy: Never
      # The Vault agent logs in with the pod's ServiceAccount token.
      automountServiceAccountToken: {{ ne $vault "" }}
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
              {{- with include "common.secretEnvExports" (list $ $s.secretEnv) | trim }}
              {{- . | nindent 14 }}
              {{- end }}
              {{- if $external }}
              # clickhouse-client takes its CA only from a config file. Verification is strict, and a certificate
              # that fails it is refused, never accepted.
              cat >/tmp/client.xml <<EOF
              <config>
                <openSSL>
                  <client>
                    <caConfig>$CLICKHOUSE_CA_FILE</caConfig>
                    <loadDefaultCAFile>false</loadDefaultCAFile>
                    <verificationMode>strict</verificationMode>
                    <invalidCertificateHandler>
                      <name>RejectCertificateHandler</name>
                    </invalidCertificateHandler>
                  </client>
                </openSSL>
              </config>
              EOF
              set -- --config-file /tmp/client.xml --port "$CLICKHOUSE_PORT" --secure --tls-sni-override "$CLICKHOUSE_TLS_SERVER_NAME"
              until clickhouse-client "$@" --query 'SELECT 1' >/dev/null; do
                echo "waiting for ClickHouse at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT"
                sleep 5
              done
              exec clickhouse-client "$@" --multiquery --queries-file /schema/schema.sql
              {{- else }}
              until clickhouse-client --query 'SELECT 1' >/dev/null; do
                echo "waiting for ClickHouse at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT"
                sleep 5
              done
              exec clickhouse-client --multiquery --queries-file /schema/schema.sql
              {{- end }}
          env:
            - name: CLICKHOUSE_HOST
              value: {{ first $address | quote }}
            - name: CLICKHOUSE_PORT
              value: {{ last $address | quote }}
            - name: CLICKHOUSE_USER
              value: otel_admin
            {{- with include "common.secretEnv" (list $ $s.secretEnv) }}
            {{- . | nindent 12 }}
            {{- end }}
            - name: HOME
              value: /tmp
            {{- if $external }}
            - name: CLICKHOUSE_CA_FILE
              value: {{ include "common.clickhouseCA" . | quote }}
            - name: CLICKHOUSE_TLS_SERVER_NAME
              value: {{ .Values.global.clickhouse.tls.serverName | quote }}
            {{- end }}
          volumeMounts:
            - name: schema
              mountPath: /schema
              readOnly: true
            - name: tmp
              mountPath: /tmp
            {{- if $external }}
            - name: clickhouse-ca
              mountPath: /etc/clickhouse-ca
              readOnly: true
            {{- end }}
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
        {{- if $external }}
        - name: clickhouse-ca
          {{- include "common.clickhouseCAVolume" . | nindent 10 }}
        {{- end }}
