{{- /*
The standalone server's data volume. Argo CD never prunes or deletes it, and helm uninstall leaves it, so a
mistake in the environment or removing the application doesn't take the data with it: delete it by hand.
*/}}
{{- $ch := .Values.clickhouse }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "common.fullname" . }}-data
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
    helm.sh/resource-policy: keep
spec:
  accessModes:
    - ReadWriteOnce
  {{- with $ch.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ $ch.storage | quote }}
