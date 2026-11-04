{{- /*
The ClickHouseInstallation the operator runs: one server unless clickhouse.shards or replicas say otherwise. Its
users and configuration are files/server.yaml.tpl, which the standalone Deployment (global.clickhouse.standalone,
files/standalone.yaml.tpl) shares.
*/}}
{{- $ch := .Values.clickhouse }}
{{- $server := tpl (.Files.Get "files/server.yaml.tpl") . | fromYaml }}
apiVersion: clickhouse.altinity.com/v1
kind: ClickHouseInstallation
metadata:
  name: otel
spec:
  defaults:
    templates:
      podTemplate: clickhouse
      dataVolumeClaimTemplate: data
      serviceTemplate: clickhouse
  configuration:
    # files/server.yaml.tpl's users, profiles, quotas and config files, in the operator's <name>/<setting> keys.
    users:
      {{- range $user, $u := $server.users }}
      {{ $user }}/password:
        valueFrom:
          secretKeyRef:
            name: {{ $u.secret }}
            key: password
      {{ $user }}/networks/ip:
        - "0.0.0.0/0"
        - "::/0"
      {{ $user }}/profile: {{ $u.profile }}
      {{ $user }}/quota: {{ $u.profile }}
      {{- with $u.grants }}
      {{ $user }}/grants/query:
        {{- range . }}
        - GRANT {{ . }}
        {{- end }}
      {{- end }}
      {{- end }}
    profiles:
      {{- range $profile, $p := $server.profiles }}
      {{- range $setting, $value := $p.settings }}
      {{ $profile }}/{{ $setting }}: {{ $value }}
      {{- end }}
      {{- range $setting, $bounds := $p.constraints }}
      {{- range $bound, $value := $bounds }}
      {{ $profile }}/constraints/{{ $setting }}/{{ $bound }}: {{ $value }}
      {{- end }}
      {{- end }}
      {{- end }}
    quotas:
      {{- range $quota, $q := $server.quotas }}
      {{- range $key, $value := $q }}
      {{ $quota }}/interval/{{ $key }}: {{ $value }}
      {{- end }}
      {{- end }}
    files:
      {{- range $file, $content := $server.files }}
      {{ $file }}: {{ toYaml $content | nindent 8 }}
      {{- end }}
    clusters:
      - name: main
        layout:
          shardsCount: {{ int $ch.shards }}
          replicasCount: {{ int $ch.replicas }}
  templates:
    serviceTemplates:
      - name: clickhouse
        generateName: clickhouse
        spec:
          type: ClusterIP
          ports:
            - name: http
              port: 8123
            - name: tcp
              port: 9000
    podTemplates:
      - name: clickhouse
        {{- if include "common.istioSidecar" $ }}
        # The operator creates these pods, so ask for the sidecar here as well as on the namespace. The
        # operator's own user may only connect from the operator pod's IP, and through a sidecar every
        # connection arrives from 127.0.0.6, so the operator's port, HTTP 8123, bypasses the sidecar here and
        # in the operator pod. The collector and Cerberus use 9000, which stays in the mesh.
        metadata:
          labels:
            sidecar.istio.io/inject: "true"
          annotations:
            traffic.sidecar.istio.io/excludeInboundPorts: "8123"
        {{- end }}
        spec:
          {{- with include "common.imagePullSecrets" (list $ list) | trim }}
          {{- . | nindent 10 }}
          {{- end }}
          containers:
            - name: clickhouse
              image: {{ include "common.image" (list $ $ch.image) | quote }}
              resources:
                {{- toYaml $ch.resources | nindent 16 }}
    volumeClaimTemplates:
      - name: data
        spec:
          accessModes:
            - ReadWriteOnce
          {{- with $ch.storageClassName }}
          storageClassName: {{ . | quote }}
          {{- end }}
          resources:
            requests:
              storage: {{ $ch.storage | quote }}
