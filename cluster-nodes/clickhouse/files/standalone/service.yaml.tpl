{{- /* The standalone server's Service: clickhouse:9000 and :8123, the names the operator's Service has. */}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.fullname" . }}
spec:
  type: ClusterIP
  selector:
    {{- include "common.clickhousePodLabels" . | nindent 4 }}
  ports:
    - name: http
      port: 8123
      targetPort: http
      protocol: TCP
    - name: tcp
      port: 9000
      targetPort: tcp
      protocol: TCP
