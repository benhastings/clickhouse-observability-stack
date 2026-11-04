{{- /* cspell:words sslv tlsv */}}
{{- /*
The standalone server's configuration (global.clickhouse.standalone): files/server.yaml.tpl, which the
ClickHouseInstallation shares, as the config.d and users.d files of the clickhouse-server image. Each user reads
its password from the environment variable CLICKHOUSE_PASSWORD_<USER>, which deployment.yaml.tpl sets from the
user's Secret, so no password is in this ConfigMap and nothing creates a user with SQL.
*/}}
{{- $server := tpl (.Files.Get "files/server.yaml.tpl") . | fromYaml }}
{{- /* With global.clickhouse.tls.vault the certificate and key are the files the Vault agent writes instead. */}}
{{- $tls := (include "common.values" . | fromYaml).global.clickhouse.tls }}
{{- $certificate := "/etc/clickhouse-server/tls/tls.crt" }}
{{- $key := "/etc/clickhouse-server/tls/tls.key" }}
{{- if include "common.clickhouseTLSVault" . }}
{{- $certificate = include "common.secretFilePath" (list . (dict "secret" $tls.serverSecret "key" "tls.crt")) }}
{{- $key = include "common.secretFilePath" (list . (dict "secret" $tls.serverSecret "key" "tls.key")) }}
{{- end }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "common.fullname" . }}-server
data:
  {{- range $file, $content := $server.files }}
  {{ base $file }}: {{ toYaml $content | nindent 4 }}
  {{- end }}
  # The listeners, and the server's logs on stdout as well as in the log directory (an emptyDir). This file
  # replaces the image's config.d, so it also listens on every address as the image's docker_related_config.xml
  # does. TLS only: the native protocol on 9440 and HTTP on 8443, with the image's plaintext native, HTTP, MySQL,
  # PostgreSQL and interserver ports removed. The one plaintext port left is Prometheus on 9363, which only the
  # collector may reach. The certificate is global.clickhouse.tls.serverSecret's, which deployment.yaml.tpl mounts;
  # the server asks no client for a certificate of its own.
  listen.xml: |
    <clickhouse>
      <listen_host>::</listen_host>
      <listen_host>0.0.0.0</listen_host>
      <listen_try>1</listen_try>
      <tcp_port remove="1"/>
      <http_port remove="1"/>
      <mysql_port remove="1"/>
      <postgresql_port remove="1"/>
      <interserver_http_port remove="1"/>
      <tcp_port_secure>9440</tcp_port_secure>
      <https_port>8443</https_port>
      <openSSL>
        <server>
          <certificateFile>{{ $certificate }}</certificateFile>
          <privateKeyFile>{{ $key }}</privateKeyFile>
          <verificationMode>none</verificationMode>
          <loadDefaultCAFile>false</loadDefaultCAFile>
          <cacheSessions>true</cacheSessions>
          <disableProtocols>sslv2,sslv3,tlsv1,tlsv1_1</disableProtocols>
          <preferServerCiphers>true</preferServerCiphers>
        </server>
      </openSSL>
      <logger>
        <console>1</console>
      </logger>
    </clickhouse>
  # The image's default user has no password and accepts any address: here it answers only on localhost.
  users.xml: |
    <clickhouse>
      <users>
        <default>
          <networks replace="replace">
            <ip>::1</ip>
            <ip>127.0.0.1</ip>
          </networks>
        </default>
        {{- range $user, $u := $server.users }}
        <{{ $user }}>
          <password from_env="CLICKHOUSE_PASSWORD_{{ upper $user }}"/>
          <networks>
            <ip>0.0.0.0/0</ip>
            <ip>::/0</ip>
          </networks>
          <profile>{{ $u.profile }}</profile>
          <quota>{{ $u.profile }}</quota>
          {{- with $u.grants }}
          <grants>
            {{- range . }}
            <query>GRANT {{ . }}</query>
            {{- end }}
          </grants>
          {{- end }}
        </{{ $user }}>
        {{- end }}
      </users>
      <profiles>
        {{- range $profile, $p := $server.profiles }}
        <{{ $profile }}>
          {{- range $setting, $value := $p.settings }}
          <{{ $setting }}>{{ $value }}</{{ $setting }}>
          {{- end }}
          {{- with $p.constraints }}
          <constraints>
            {{- range $setting, $bounds := . }}
            <{{ $setting }}>
              {{- range $bound, $value := $bounds }}
              <{{ $bound }}>{{ $value }}</{{ $bound }}>
              {{- end }}
            </{{ $setting }}>
            {{- end }}
          </constraints>
          {{- end }}
        </{{ $profile }}>
        {{- end }}
      </profiles>
      <quotas>
        {{- range $quota, $q := $server.quotas }}
        <{{ $quota }}>
          <interval>
            {{- range $key, $value := $q }}
            <{{ $key }}>{{ $value }}</{{ $key }}>
            {{- end }}
          </interval>
        </{{ $quota }}>
        {{- end }}
      </quotas>
    </clickhouse>
