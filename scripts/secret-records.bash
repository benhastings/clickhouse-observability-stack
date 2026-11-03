#!/usr/bin/env bash
# cspell:words tostring
# secret-records.bash <dir>: the credential records one rendered environment needs, read from its render
# (scripts/render.bash, or tests/golden/<env>: one <app>.yaml per application). For each app it prints the
# secret mechanism its pods use, then every record that mechanism has to hold before the first sync:
#   <app>  kubernetes       Secret <name>, key <key>
#   <app>  vault            <path>, field <field>
#   <app>  externalSecrets  <remote key>, property <property> (store <store>, Secret <name>)
# A Secret the render creates itself is not listed. It reads names, keys, paths and fields only, never a value.
set -euo pipefail

dir=${1:?usage: secret-records.bash <rendered-environment-dir>}

# Every record, as "<mechanism>\t<record>", from one app's render.
records() {
  local file=$1
  # Vault: each agent-inject-template annotation reads one field of one record.
  yq ea -N 'select(.kind != "CustomResourceDefinition") | .. | select(tag == "!!map") | to_entries | .[] |
    select(.key | test("^vault.hashicorp.com/agent-inject-template-")) | .value |
    "vault\t" + capture("with secret \"(?P<p>[^\"]+)\"").p + ", field " + capture("index \.Data\.data \"(?P<f>[^\"]+)\"").f' "$file"
  # External Secrets: each data entry is one property of one remote key.
  # shellcheck disable=SC2016 # $store and $name are yq variables
  yq e -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name as $store | .spec.target.name as $name |
    .spec.data[] | "externalSecrets\t" + .remoteRef.key + ", property " + .remoteRef.property +
    " (store " + $store + ", Secret " + $name + ")"' "$file"
  # Kubernetes: a Secret a pod reads by key that no application renders. One an ExternalSecret anywhere in the
  # environment fills is that ExternalSecret's record, listed above for the app that renders it. The ClickHouse
  # operator names its Secret in its config.yaml (clickhouse.access.secret) instead of a secretKeyRef.
  yq ea -N 'select(.kind != "CustomResourceDefinition") | .. | select(has("secretKeyRef")) | .secretKeyRef |
    .name + "\t" + .key + "\t" + (.optional // false | tostring)' "$file" |
    cat - <(yq e -N 'select(.kind == "ConfigMap") | .data["config.yaml"] | select(.) | from_yaml |
      .clickhouse.access.secret.name | select(.) | (. + "\tusername\tfalse", . + "\tpassword\tfalse")' "$file") |
    while IFS=$'\t' read -r name key optional; do
      [[ -z "$name" ]] && continue
      grep -qxF "$name" <<<"$created" && continue
      [[ "$optional" == true ]] && key+=" (optional)"
      if grep -qxF "$name" <<<"$external"; then
        printf 'externalSecrets\tSecret %s, key %s, filled by its ExternalSecret\n' "$name" "$key"
      else
        printf 'kubernetes\tSecret %s, key %s\n' "$name" "$key"
      fi
    done
}

shopt -s nullglob
apps=()
for file in "$dir"/*.yaml; do
  [[ "$(basename "$file")" == app-of-apps.yaml ]] || apps+=("$file")
done
((${#apps[@]})) || { echo "secret-records: no rendered applications in $dir" >&2; exit 2; }
# The Secrets the environment renders itself, and those an ExternalSecret fills, in any application.
created="$(yq ea -N 'select(.kind == "Secret") | .metadata.name' "${apps[@]}" | sort -u)"
external="$(yq ea -N 'select(.kind == "ExternalSecret") | .spec.target.name' "${apps[@]}" | sort -u)"

for file in "${apps[@]}"; do
  app="$(basename "$file" .yaml)"
  list="$(records "$file" | sort -u)"
  [[ -z "$list" ]] && continue
  mechanisms="$(cut -f1 <<<"$list" | sort -u | paste -sd' ')"
  if [[ "$mechanisms" == *' '* ]]; then
    echo "secret-records: $app reads credentials through more than one mechanism ($mechanisms)" >&2
    exit 1
  fi
  while IFS=$'\t' read -r mechanism record; do
    printf '%-19s %-16s %s\n' "$app" "$mechanism" "$record"
  done <<<"$list"
done
