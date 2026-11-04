{{- /*
The standalone server's Service, TLS only: clickhouse:9440 (native) and :8443 (HTTPS), named tcp-* so Istio
passes the server's TLS through as opaque TCP. No plaintext 9000 or 8123; the collector scrapes 9363 by pod IP.
*/}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.fullname" . }}
spec:
  type: ClusterIP
  selector:
    {{- include "common.clickhousePodLabels" . | nindent 4 }}
  ports:
    - name: tcp-https
      port: 8443
      targetPort: tcp-https
      protocol: TCP
    - name: tcp-native
      port: 9440
      targetPort: tcp-native
      protocol: TCP
