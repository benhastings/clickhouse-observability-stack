{{- $a := .Values.alerts }}
{{- $cp := $a.contactPoint | default dict }}
{{- if and $cp (not $cp.name) }}
{{- fail "alerts.contactPoint needs a name, a type and its settings" }}
{{- end }}
{{- $notify := "" }}
{{- if $cp.name }}
{{- $notify = printf "\n            notification_settings:\n              receiver: %s" ($cp.name | toJson) }}
{{- end }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "common.fullname" . }}-alerts
  labels:
    {{- include "common.labels" . | nindent 4 }}
data:
  alerts.yaml: |
    # Starter alert rules. They query Cerberus through the cerberus-prometheus datasource.
    {{- if not $cp.name }}
    # No contact point is set (alerts.contactPoint), so these rules fire in Grafana but notify nobody.
    {{- end }}
    apiVersion: 1
    {{- with $cp.name }}
    contactPoints:
      - orgId: 1
        name: {{ . | toJson }}
        receivers:
          - uid: observability-stack-contact
            type: {{ required "alerts.contactPoint.type is required" $cp.type | toJson }}
            settings:
              {{- toYaml ($cp.settings | default dict) | nindent 14 }}
    {{- end }}
    groups:
      - orgId: 1
        name: observability-stack
        folder: Observability stack
        interval: 1m
        rules:
          - uid: stack-span-error-ratio
            title: Span error ratio above {{ $a.errorRatio.threshold }}
            condition: C
            for: {{ $a.errorRatio.for }}
            noDataState: OK
            execErrState: Error
            labels:
              severity: warning
            annotations:
              summary: The share of server spans that end in an error is above the threshold for a service.
            data:
              - refId: A
                relativeTimeRange: {from: 600, to: 0}
                datasourceUid: cerberus-prometheus
                model:
                  refId: A
                  instant: true
                  expr: >-
                    sum by (service_name) (rate(traces_span_metrics_calls{span_kind="SPAN_KIND_SERVER",
                    status_code="STATUS_CODE_ERROR", service_name=~{{ $a.errorRatio.serviceName | toJson }}}[5m]))
                    / sum by (service_name) (rate(traces_span_metrics_calls{span_kind="SPAN_KIND_SERVER",
                    service_name=~{{ $a.errorRatio.serviceName | toJson }}}[5m]))
              - refId: C
                datasourceUid: __expr__
                model:
                  refId: C
                  type: threshold
                  expression: A
                  conditions:
                    - evaluator: {type: gt, params: [{{ $a.errorRatio.threshold }}]}
            {{- $notify }}
          - uid: stack-collector-no-spans
            title: The collector received no spans for 15 minutes
            condition: C
            for: 0s
            noDataState: Alerting
            execErrState: Error
            labels:
              severity: critical
            annotations:
              summary: No span metrics in the last 15 minutes, so the collector is down or nothing is sending.
            data:
              - refId: A
                relativeTimeRange: {from: 900, to: 0}
                datasourceUid: cerberus-prometheus
                model:
                  refId: A
                  instant: true
                  expr: sum(increase(traces_span_metrics_calls[15m]))
              - refId: C
                datasourceUid: __expr__
                model:
                  refId: C
                  type: threshold
                  expression: A
                  conditions:
                    - evaluator: {type: lt, params: [1]}
            {{- $notify }}
          {{- if $a.clickhouseDisk.enabled }}
          - uid: stack-clickhouse-disk
            title: ClickHouse disk above {{ $a.clickhouseDisk.threshold }} full
            condition: C
            for: 15m
            noDataState: NoData
            execErrState: Error
            labels:
              severity: warning
            annotations:
              summary: A ClickHouse data volume is filling up. It reads kubeletstats volume metrics.
            data:
              - refId: A
                relativeTimeRange: {from: 600, to: 0}
                datasourceUid: cerberus-prometheus
                model:
                  refId: A
                  instant: true
                  expr: >-
                    1 - sum by (k8s_pod_name) (k8s_volume_available{k8s_pod_name=~"chi-otel-.*", k8s_volume_name="data"})
                    / sum by (k8s_pod_name) (k8s_volume_capacity{k8s_pod_name=~"chi-otel-.*", k8s_volume_name="data"})
              - refId: C
                datasourceUid: __expr__
                model:
                  refId: C
                  type: threshold
                  expression: A
                  conditions:
                    - evaluator: {type: gt, params: [{{ $a.clickhouseDisk.threshold }}]}
            {{- $notify }}
          {{- end }}
