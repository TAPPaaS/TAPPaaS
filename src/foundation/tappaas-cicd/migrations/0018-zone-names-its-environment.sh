#!/usr/bin/env bash
# 0018-zone-names-its-environment.sh — each zone names its environment; environments name no zone
#
# Introduced: 2.3.  Required by: #865 (src/DATAMODEL.md finding 1).
# Touches: config/zones.json and config/environments/*.json (only).
# Reversible: yes — restore config/.migrations/backup/0018/ (zones.json and environments/).
#
# WHY. The environment ↔ zone link ran both ways: an environment named its
# service zone (environments/<env>.json `network.zone`) and a Client, IoT or
# Guest zone named the environment(s) it serves (zones.json `serves`). Two
# fields for one fact, in two files, kept in step by hand. Now the zone names
# the environment and nothing points the other way: one `environment` field per
# zone — on a Service zone (or mgmt) the environment whose zone it is, on a
# Client/IoT/Guest zone the environment it serves, or the list of them when it
# serves several (a `serves` list is carried over as it is). A Service zone no
# environment names as its own and that serves environments is a shared
# service zone: its `serves` becomes the list, kept a list even of one.
#
# What it writes: `environment` on every zone an environment names as its
# `network.zone`, and on every zone carrying `serves`; then it removes
# `network` from every environment file and `serves` from every zone. The
# firewall sees the same graph: a served environment's edge is derived from the
# same zone as before.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - a zone two environment files both name as their service zone, a zone whose
#     `serves` disagrees with the environment naming it as its own, and a zone
#     that already names another environment than the one naming it as its own
#     — the person decides which environment the zone is;
#   - an environment whose `network.zone` is not in zones.json, or is not a
#     Service or Management zone;
#   - `serves` on a zone that is not Client, IoT, Guest or a shared Service
#     zone, or that is not a name or a list of names;
#   - an environment file whose `name` differs from its file name, or that is
#     not JSON.
#
# Usage: 0018-zone-names-its-environment.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0018}"
ZONES="${CONFIG_DIR}/zones.json"
ENVDIR="${CONFIG_DIR}/environments"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0018: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0018: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0018: $*" >&2; exit 1; }

[[ -f "${ZONES}" ]] || { say "no ${ZONES} — nothing to migrate"; exit 0; }
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to guess"

# The environments: [{name, file, zone, hasNet}] from environments/*.json.
env_files=()
if [[ -d "${ENVDIR}" ]]; then
    for f in "${ENVDIR}"/*.json; do
        [[ -e "${f}" ]] || continue
        jq empty "${f}" 2>/dev/null || stop "${f} is not valid JSON — refusing to guess"
        env_files+=("${f}")
    done
fi
if [[ ${#env_files[@]} -gt 0 ]]; then
    envs="$(jq -n '[inputs | {file: input_filename, self: (.name // null),
                              name: (input_filename | split("/") | last | rtrimstr(".json")),
                              zone: (.network.zone // null), hasNet: has("network")}]' "${env_files[@]}")"
else
    envs='[]'
fi

# The plan, from zones.json and the environments: what each zone will name,
# and every reason to stop.
plan="$(jq --argjson E "${envs}" '
    def zs: to_entries | map(select((.key | startswith("_") | not) and (.value | type) == "object"));
    def servesof(v): if v == null then [] elif (v | type) == "string" then [v]
                     elif (v | type) == "array" and all(v[]; type == "string") then v
                     else null end;
    zs as $Z
    | ([$Z[].key]) as $keys
    | [ $Z[] | . as $z
        | ($E | map(select(.zone == $z.key) | .name)) as $own
        | servesof($z.value.serves) as $sv
        | (servesof($z.value.environment) // []) as $cur
        # its own zone: the one environment naming it; else every one it serves, in order
        | (if ($own | length) > 0 then ($own + $cur)
           else (($sv // []) + $cur) end
           | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $envs
        # a Service zone no environment names as its own, that serves or lists
        # environments, is a shared service zone: its value stays a list
        | (($z.value.type // "") == "Service" and ($own | length) == 0
           and (($z.value | has("serves")) or (($z.value.environment | type) == "array"))) as $shared
        | { zone: $z.key, type: ($z.value.type // ""), own: $own, serves: $sv,
            hadServes: ($z.value | has("serves")), shared: $shared,
            current: ($z.value.environment // null),
            envs: $envs,
            value: (if ($envs | length) == 0 then null elif $shared or ($envs | length) > 1 then $envs else $envs[0] end) } ] as $P
    | { zones: $P,
        problems: (
          [ $E[] | select(.self != null and .self != .name)
                 | "environments/\(.name).json says name \"\(.self)\" — the file name is the environment" ]
        + [ $E[] | select(.zone != null and (.zone | type) != "string")
                 | "environment \(.name): network.zone \(.zone | tojson) is not a zone name" ]
        + [ $E[] | select((.zone | type) == "string") | . as $e | select($keys | index($e.zone) | not)
                 | "environment \($e.name) names zone \($e.zone), which is not in zones.json" ]
        + [ $P[] | select((.own | length) > 0 and (.type | IN("Service", "Management") | not))
                 | "environment \(.own | join(", ")) names zone \(.zone) as its zone, but that is a \(if .type == "" then "untyped" else .type end) zone" ]
        + [ $P[] | select(.hadServes and .serves == null)
                 | "zone \(.zone): serves is not an environment name or a list of them" ]
        + [ $P[] | select((.serves // []) | length > 0) | select(.type | IN("Client", "IoT", "Guest") | not) | select(.shared | not)
                 | "zone \(.zone) is a \(if .type == "" then "untyped" else .type end) zone and carries serves (only Client, IoT and Guest zones, and a Service zone no environment names as its own, serve an environment)" ]
        + [ $P[] | select((.own | length) > 1)
                 | "zone \(.zone) is named as their zone by \(.own | length) environments (\(.own | join(", "))) — a zone is the zone of one environment" ]
        + [ $P[] | select((.own | length) == 1 and (.serves // []) != [] and (.serves // []) != .own)
                 | "zone \(.zone) is environment \(.own[0])'"'"'s zone but serves \(.serves | join(", "))" ]
        + [ $P[] | select((.own | length) == 1 and (.envs | length) > 1)
                 | "zone \(.zone) is environment \(.own[0])'"'"'s zone but already names \(.envs - .own | join(", "))" ]
        + ( [ $P[] | select(.type | IN("Service", "Management")) | select((.envs | length) == 1 and (.shared | not)) | {e: .envs[0], z: .zone} ]
            | group_by(.e) | map(select(length > 1))
            | map("environment \(.[0].e) would be named by \(length) Service/Management zones (\(map(.z) | join(", ")))") )
        ) }' "${ZONES}")"

problems="$(jq -r '.problems[]' <<<"${plan}")"
if [[ -n "${problems}" ]]; then
    while IFS= read -r p; do echo -e "\033[01;31m[Error]\033[m 0018: ${p}" >&2; done <<<"${problems}"
    stop "refusing to migrate — zones.json and environments/ are unchanged; a person should look at this"
fi

# What changes: zones that gain (or keep) a link, zones that lose `serves`,
# environment files that lose `network`.
links="$(jq -r '.zones[] | select(.value != null and .current != .value)
                | "\(.zone) \(.envs | join(",")) \(if (.own | length) > 0 then "own" elif .shared then "shared" else "serves" end)"' <<<"${plan}")"
drop_serves="$(jq -r '.zones[] | select(.hadServes) | .zone' <<<"${plan}")"
drop_net="$(jq -r '.[] | select(.hasNet) | .file' <<<"${envs}")"

if [[ -z "${links}" && -z "${drop_serves}" && -z "${drop_net}" ]]; then
    say "every zone names its environment and no environment names a zone — nothing to migrate"
    exit 0
fi

describe() {
    local verb="$1" z e how
    while read -r z e how; do
        [[ -n "${z}" ]] || continue
        if [[ "${how}" == own ]]; then say "${verb} zone ${z} environment ${e} (its zone)"
        elif [[ "${how}" == shared ]]; then say "${verb} zone ${z} environment ${e//,/, } (a shared service zone: it serves ${e//,/, })"
        else say "${verb} zone ${z} environment ${e//,/, } (it serves ${e//,/, })"; fi
    done <<<"${links}"
}

if [[ "${CHECK}" -eq 1 ]]; then
    describe "would give"
    [[ -z "${drop_serves}" ]] || say "would remove serves from: ${drop_serves//$'\n'/, }"
    [[ -z "${drop_net}" ]] || say "would remove network from: $(xargs -n1 basename <<<"${drop_net}" | paste -sd, - | sed 's/,/, /g')"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}/environments" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    cp -p "${f}" "${BACKUP_DIR}/environments/" || stop "cannot back up ${f} — refusing to write"
done <<<"${drop_net}"

# Render every new file first; move them into place only when all are good.
tmps=()
cleanup() { local t; for t in "${tmps[@]}"; do rm -f "${t}"; done; }
ztmp="${ZONES}.0018.tmp"; tmps+=("${ztmp}")
jq --argjson P "$(jq -c '.zones' <<<"${plan}")" '
    reduce $P[] as $p (.;
        if $p.value != null then .[$p.zone].environment = $p.value else . end
        | if $p.hadServes then .[$p.zone] |= del(.serves) else . end)' "${ZONES}" > "${ztmp}" \
    || { cleanup; stop "rewrite of zones.json failed — nothing is changed"; }
jq empty "${ztmp}" 2>/dev/null || { cleanup; stop "the rewritten zones.json is not valid JSON — nothing is changed"; }
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    t="${f}.0018.tmp"; tmps+=("${t}")
    jq 'del(.network)' "${f}" > "${t}" || { cleanup; stop "rewrite of ${f} failed — nothing is changed"; }
done <<<"${drop_net}"

chmod --reference="${BACKUP_DIR}/zones.json" "${ztmp}" 2>/dev/null || true
mv -f "${ztmp}" "${ZONES}"
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    chmod --reference="${f}" "${f}.0018.tmp" 2>/dev/null || true
    mv -f "${f}.0018.tmp" "${f}"
done <<<"${drop_net}"

describe "gave"
[[ -z "${drop_serves}" ]] || say "removed serves from: ${drop_serves//$'\n'/, }"
[[ -z "${drop_net}" ]] || say "removed network from: $(xargs -n1 basename <<<"${drop_net}" | paste -sd, - | sed 's/,/, /g')"
note "backup: ${BACKUP_DIR}"
