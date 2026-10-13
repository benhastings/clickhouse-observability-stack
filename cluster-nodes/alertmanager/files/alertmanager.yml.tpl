{{- /*
alertmanager.yml. The stack's own routes come first and every environment keeps them:
  history    every alert, one per notification, posted to the collector so it is kept in otel_logs; continue: true
  heartbeat  vmalert's always-firing Watchdog, every minute, for a dead man's switch; it stops there
  slack      with slack.enabled, every other alert, one Slack thread per alert group; continue: true. Its own
             AlertmanagerNotificationsFailing for integration slack goes to default instead, not to the
             receiver that is failing.
Then the environment's route.routes, under its route, and its receivers. Last, a route with no matchers sends
whatever got that far to route.receiver: an alert that matched a route above, even one with continue: true,
is never sent to its parent's own receiver.
*/ -}}
{{- $v := .Values }}
{{- $routes := list
  (dict "receiver" "history" "group_by" (list "...") "group_wait" "0s" "group_interval" "1m" "repeat_interval" "168h" "continue" true)
  (dict "receiver" "heartbeat" "matchers" (list "alertname=\"Watchdog\"") "group_by" (list "alertname") "group_wait" "0s" "group_interval" "1m" "repeat_interval" "1m") }}
{{- $receivers := list
  (dict "name" "history" "webhook_configs" (list (dict "url" (include "common.serviceAddress" (list $ "alertHistory")) "send_resolved" true "max_alerts" 1)))
  (dict "name" "heartbeat") }}
{{- with $v.slack }}{{ if .enabled }}
{{- $routes = append $routes (dict "receiver" $v.route.receiver "matchers" (list "alertname=\"AlertmanagerNotificationsFailing\"" "integration=\"slack\"")) }}
{{- $routes = append $routes (dict "receiver" "slack" "group_by" (list "alertname" "service_name") "continue" true) }}
{{- $receivers = append $receivers (dict "name" "slack" "slack_configs" (list (dict
  "app_token_file" "/etc/alertmanager/slack/app-token"
  "app_url" "https://slack.com/api/chat.postMessage"
  "channel" (required "slack.channel is required when slack.enabled" .channel)
  "send_resolved" true
  "update_message" true
  "post_updates_to_thread" true))) }}
{{- end }}{{ end }}
{{- $route := omit $v.route "routes" }}
{{- $_ := set $route "routes" (concat $routes ($v.route.routes | default list) (list (dict "receiver" $v.route.receiver))) }}
{{- toYaml (dict "route" $route "receivers" (concat $receivers $v.receivers) "templates" (list "/etc/alertmanager/templates/*.tmpl")) }}
