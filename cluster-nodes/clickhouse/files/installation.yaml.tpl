{{- $ch := .Values.clickhouse }}
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
    users:
      otel/password:
        valueFrom:
          secretKeyRef:
            name: {{ include "common.fullname" . }}-credentials
            key: password
      otel/networks/ip:
        - "0.0.0.0/0"
        - "::/0"
      otel/profile: default
      otel/quota: default
    {{- if $ch.lowMemory }}
    profiles:
      default/max_threads: 2
      default/max_memory_usage: 536870912
    files:
      config.d/low_memory.xml: |
        <clickhouse>
          <max_server_memory_usage_to_ram_ratio>0.75</max_server_memory_usage_to_ram_ratio>
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
