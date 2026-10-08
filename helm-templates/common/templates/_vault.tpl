{{- /* cspell:words daemonset */ -}}
{{- define "common.vaultEnabled" -}}
{{- $v := include "common.values" . | fromYaml -}}
{{- if $v.vault.enabled }}true{{ end -}}
{{- end -}}

{{- /* (list $root $workload): true when Vault is on and the pod declares any secretEnv. */ -}}
{{- define "common.vaultInjected" -}}
{{- $root := index . 0 -}}
{{- $d := index . 1 -}}
{{- if include "common.vaultEnabled" $root }}
{{- range $name, $c := $d.containers }}
{{- if and $c $c.secretEnv }}true{{ end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "common.secretFilePath" -}}
{{- $root := index . 0 -}}
{{- $s := index . 1 -}}
{{- $vault := default (dict) $s.vault -}}
{{- default (printf "/vault/secrets/%s-%s" (tpl $s.secret $root) $s.key) $vault.file -}}
{{- end -}}

{{- /* (list $root "<container>" "<NAME>"): the container is looked up in deployment, then daemonset. */ -}}
{{- define "common.secretFile" -}}
{{- $root := index . 0 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $c := index (default (dict) $v.deployment.containers) (index . 1) -}}
{{- if not (and $c (hasKey (default (dict) $c.secretEnv) (index . 2))) -}}
{{- $c = index (default (dict) $v.daemonset.containers) (index . 1) -}}
{{- end -}}
{{- $s := index (default (dict) (and $c $c.secretEnv)) (index . 2) -}}
{{- include "common.secretFilePath" (list $root (required (printf "common.secretFile: no secretEnv %s in container %s" (index . 2) (index . 1)) $s)) -}}
{{- end -}}

{{- define "common.vaultTemplate" -}}
{{- $path := index . 0 -}}
{{- $s := index . 1 -}}
{{- $vault := default (dict) $s.vault -}}
{{- $value := printf "index .Data.data %q" $s.key -}}
{{- if $vault.yamlKey -}}
{{- $keys := splitList "." $vault.yamlKey -}}
{{- $body := "" -}}
{{- range $i, $k := $keys -}}
{{- $body = printf "%s%s%s:" $body (repeat (int (mul $i 2)) " ") $k -}}
{{- if eq (add1 $i) (len $keys) -}}
{{- $body = printf "%s {{ %s | toJSON }}" $body $value -}}
{{- else -}}
{{- $body = printf "%s\n" $body -}}
{{- end -}}
{{- end -}}
{{- printf "{{- with secret %q -}}\n%s\n{{- end -}}" $path $body -}}
{{- else -}}
{{- printf "{{- with secret %q -}}{{ %s }}{{- end -}}" $path $value -}}
{{- end -}}
{{- end -}}

{{- /* (list $root $workload): the Vault Agent Injector annotations for one pod. */ -}}
{{- define "common.vaultAnnotations" -}}
{{- $root := index . 0 -}}
{{- $d := index . 1 -}}
{{- $v := include "common.values" $root | fromYaml -}}
{{- $annotations := dict "vault.hashicorp.com/agent-inject" "true" "vault.hashicorp.com/role" (default (include "common.fullname" $root) $v.vault.role) -}}
{{- range $name, $c := $d.containers }}
{{- if $c }}
{{- range $envName, $s := $c.secretEnv }}
{{- if $s }}
{{- $file := include "common.secretFilePath" (list $root $s) -}}
{{- $path := printf "%s/%s" (trimSuffix "/" $v.vault.path) (tpl $s.secret $root) -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-secret-%s" (base $file)) $path -}}
{{- $_ := set $annotations (printf "vault.hashicorp.com/agent-inject-template-%s" (base $file)) (include "common.vaultTemplate" (list $path $s)) -}}
{{- if ne (dir $file) "/vault/secrets" }}
{{- $_ := set $annotations (printf "vault.hashicorp.com/secret-volume-path-%s" (base $file)) (dir $file) -}}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml (mustMergeOverwrite $annotations (default (dict) $v.vault.annotations)) -}}
{{- end -}}
