{{- /*
The standalone server's configuration (global.clickhouse.standalone): files/server.yaml.tpl, which the
ClickHouseInstallation shares, as the config.d and users.d files of the clickhouse-server image. Each user reads
its password from the environment variable CLICKHOUSE_PASSWORD_<USER>, which deployment.yaml.tpl sets from the
user's Secret, so no password is in this ConfigMap and nothing creates a user with SQL.
*/}}
{{- $server := tpl (.Files.Get "files/server.yaml.tpl") . | fromYaml }}
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
  # does.
  listen.xml: |
    <clickhouse>
      <listen_host>::</listen_host>
      <listen_host>0.0.0.0</listen_host>
      <listen_try>1</listen_try>
      <http_port>8123</http_port>
      <tcp_port>9000</tcp_port>
      <interserver_http_port remove="1"/>
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
