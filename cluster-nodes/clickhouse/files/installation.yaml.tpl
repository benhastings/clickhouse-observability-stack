{{- $ch := .Values.clickhouse }}
{{- if and $ch.garmr.enabled (not $ch.keeper.embedded) }}
{{- fail "clickhouse.garmr.enabled needs clickhouse.keeper.embedded: garmr keeps its open incidents in a KeeperMap table" }}
{{- end }}
{{- if and $ch.keeper.embedded (gt (mul (int $ch.shards) (int $ch.replicas)) 1) }}
{{- fail "clickhouse.keeper.embedded runs one Keeper inside one server; more shards or replicas need a ClickHouseKeeperInstallation" }}
{{- end }}
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
    # The users values.yaml describes under secrets. otel_admin has no grants list, so it has every
    # privilege; the others have only theirs. The schema's materialized views run as otel_admin, so an
    # insert as otel_writer needs no SELECT. otel_reader also reads the anomaly baselines, the SLO views and
    # the baselines' refresh status, for vmalert's rules. otel_analyst reads the telemetry, the feature views and the SLOs, and
    # writes only to otel_ml, under its own profile and quota. With clickhouse.garmr, otel_garmr writes garmr's
    # own tables (ALTER UPDATE and DELETE for the state in garmr.open_incidents) and reads the telemetry it
    # enriches incidents from.
    users:
      {{- $users := dict
        "admin" (dict "grants" list "profile" "default")
        "writer" (dict "grants" (list "INSERT ON otel.*") "profile" "default")
        "reader" (dict "grants" (list "SELECT ON otel.*" "SELECT ON otel_baseline.*" "SELECT ON otel_slo.*" "SELECT ON system.view_refreshes" "SELECT ON system.disks") "profile" "default")
        "analyst" (dict "grants" (list "SELECT ON otel.*" "SELECT ON otel_baseline.*" "SELECT ON otel_features.*" "SELECT ON otel_slo.*" "INSERT ON otel_ml.*") "profile" "analyst") }}
      {{- if $ch.garmr.enabled }}
      {{- $_ := set $users "garmr" (dict "grants" (list "SELECT, INSERT, ALTER UPDATE, ALTER DELETE ON garmr.*" "SELECT ON otel.*" "SELECT ON otel_features.*" "SELECT ON otel_baseline.*") "profile" "default") }}
      {{- end }}
      {{- range $user, $u := $users }}
      otel_{{ $user }}/password:
        valueFrom:
          secretKeyRef:
            name: {{ include "common.fullname" $ }}-{{ $user }}
            key: password
      otel_{{ $user }}/networks/ip:
        - "0.0.0.0/0"
        - "::/0"
      otel_{{ $user }}/profile: {{ $u.profile }}
      otel_{{ $user }}/quota: {{ $u.profile }}
      {{- with $u.grants }}
      otel_{{ $user }}/grants/query:
        {{- range . }}
        - GRANT {{ . }}
        {{- end }}
      {{- end }}
      {{- end }}
    {{- $analyst := $ch.analyst }}
    # analyst doesn't inherit default (<profile>): the operator writes a profile's keys in alphabetical order,
    # so an inherited <profile> comes last and its max_memory_usage would replace analyst's own cap.
    profiles:
      {{- if $ch.lowMemory }}
      default/max_threads: 2
      default/max_memory_usage: 536870912
      analyst/max_threads: 2
      {{- end }}
      {{- range $setting, $value := dict "max_memory_usage" $analyst.maxMemoryUsage "max_execution_time" $analyst.maxExecutionTime "max_rows_to_read" $analyst.maxRowsToRead "max_concurrent_queries_for_user" $analyst.maxConcurrentQueries }}
      analyst/{{ $setting }}: {{ int64 $value }}
      analyst/constraints/{{ $setting }}/max: {{ int64 $value }}
      {{- end }}
      analyst/priority: {{ int64 $analyst.priority }}
      analyst/constraints/priority/min: {{ int64 $analyst.priority }}
    quotas:
      analyst/interval/duration: 3600
      analyst/interval/queries: {{ int64 $analyst.quota.queries }}
      analyst/interval/read_rows: {{ int64 $analyst.quota.readRows }}
      analyst/interval/execution_time: {{ int64 $analyst.quota.executionTime }}
    files:
      # The collector scrapes every replica here (the otel-collector node's prometheus/stack receiver).
      config.d/prometheus.xml: |
        <clickhouse>
          <prometheus>
            <endpoint>/metrics</endpoint>
            <port>9363</port>
            <metrics>true</metrics>
            <events>true</events>
            <asynchronous_metrics>true</asynchronous_metrics>
            <errors>true</errors>
          </prometheus>
        </clickhouse>
      {{- if $ch.keeper.embedded }}
      # A Keeper inside this server, for KeeperMap tables (garmr's open incidents), with its log and snapshots
      # on the data volume. It costs about 70 MiB of resident memory (benhastings/garmr#2).
      config.d/keeper.xml: |
        <clickhouse>
          <keeper_server>
            <tcp_port>9181</tcp_port>
            <server_id>1</server_id>
            <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
            <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
            <coordination_settings>
              <session_timeout_ms>30000</session_timeout_ms>
            </coordination_settings>
            <raft_configuration>
              <server>
                <id>1</id>
                <hostname>localhost</hostname>
                <port>9234</port>
              </server>
            </raft_configuration>
          </keeper_server>
          <zookeeper>
            <node>
              <host>localhost</host>
              <port>9181</port>
            </node>
          </zookeeper>
          <keeper_map_path_prefix>/keeper_map_tables</keeper_map_path_prefix>
        </clickhouse>
      {{- end }}
      {{- if $ch.lowMemory }}
      # A fixed cap at 90% of the container: ClickHouse checks its resident memory against it, and that
      # includes about 460 MiB of the server binary's own code, so 75% left a 1 GiB container about 300 MiB
      # for queries and inserts. The dynamic limit (the default) lowers the cap as the page cache grows.
      config.d/low_memory.xml: |
        <clickhouse>
          <max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>
          <memory_worker_dynamic_hard_limit>false</memory_worker_dynamic_hard_limit>
          <mark_cache_size>67108864</mark_cache_size>
          <uncompressed_cache_size>0</uncompressed_cache_size>
          <index_mark_cache_size>0</index_mark_cache_size>
          <index_uncompressed_cache_size>0</index_uncompressed_cache_size>
          <background_schedule_pool_size>8</background_schedule_pool_size>
          <background_common_pool_size>4</background_common_pool_size>
          <background_fetches_pool_size>2</background_fetches_pool_size>
          <background_move_pool_size>2</background_move_pool_size>
          <background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>
          <background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>
          <background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>
          <asynchronous_metric_log remove="1"/>
          <metric_log remove="1"/>
          <query_metric_log remove="1"/>
          <trace_log remove="1"/>
          <text_log remove="1"/>
          <part_log remove="1"/>
          <processors_profile_log remove="1"/>
          <opentelemetry_span_log remove="1"/>
          <latency_log remove="1"/>
          <error_log remove="1"/>
          <query_thread_log remove="1"/>
          <query_views_log remove="1"/>
          <session_log remove="1"/>
          <blob_storage_log remove="1"/>
        </clickhouse>
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
        {{- if eq (include "common.mesh" $) "istio" }}
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
