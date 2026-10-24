#!/usr/bin/env bash
# 0023-shared-service-zones-repaired.sh — an environment named as its own by two zones keeps one
#
# Introduced: 2.3.  Required by: #876 (ADR-014 v1.6).
# Touches: config/zones.json (only).
# Reversible: yes — restore config/.migrations/backup/0023/zones.json.
#
# WHY. A Service zone may serve several environments: `environment` as a list
# makes it a shared service zone, the own zone of none, while a string names the
# environment whose own zone it is. 0018 as it first shipped collapsed a
# one-entry `serves` list on a shared Service zone into a string, so on a site
# that ran it the shared zone now claims to be a second own zone of that
# environment, and `network-manager validate` refuses the site.
#
# What it writes: for every environment named as a single string by more than
# one Service or Management zone, one of them stays its own zone and every other
# becomes shared — its string becomes a one-element list. The one kept is
#   1. the zone the environment named as its `network.zone` before 0018 ran
#      (0018's pre-image, .migrations/backup/0018/environments/<env>.json);
#   2. else the zone whose name is the environment's.
# A site where every environment has at most one such zone is left as it is.
# No firewall rule changes: a shared service zone derives no edge.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - an environment whose competing zones neither rule decides — each is named,
#     with `network-manager bind <zone> --environment <env> --add` to make one
#     shared by hand;
#   - a Management zone that would have to become shared (it never is).
#
# Usage: 0023-shared-service-zones-repaired.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0023}"
# 0018's pre-image sits beside this migration's own backup set.
PRE0018="${TAPPAAS_MIGRATION_0018_PREIMAGE:-$(dirname "${BACKUP_DIR}")/0018}"
ZONES="${CONFIG_DIR}/zones.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0023: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0023: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0023: $*" >&2; exit 1; }

[[ -f "${ZONES}" ]] || { say "no ${ZONES} — nothing to migrate"; exit 0; }
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to guess"
[[ "$(jq -r 'type' "${ZONES}")" == "object" ]] || stop "${ZONES} is not a JSON object — a person should look at this"

# The environments named as their own by more than one zone: {env: [zone, ...]}.
contested="$(jq -c '
    [ to_entries[] | select((.key | startswith("_") | not) and (.value | type) == "object")
      | select((.value.type // "") | IN("Service", "Management"))
      | select((.value.environment | type) == "string" and .value.environment != "")
      | {zone: .key, env: .value.environment} ]
    | group_by(.env) | map(select(length > 1) | {key: .[0].env, value: map(.zone)}) | from_entries' "${ZONES}")"

if [[ "${contested}" == "{}" ]]; then
    say "every environment has at most one zone of its own — nothing to migrate"
    exit 0
fi

# The zone each contested environment named before 0018: {env: zone}.
before='{}'
for env in $(jq -r 'keys[]' <<<"${contested}"); do
    f="${PRE0018}/environments/${env}.json"
    [[ -f "${f}" ]] || continue
    z="$(jq -r '.network.zone // empty | strings' "${f}" 2>/dev/null || true)"
    [[ -n "${z}" ]] || continue
    note "0018 pre-image: ${env} named ${z}"
    before="$(jq -c --arg e "${env}" --arg z "${z}" '. + {($e): $z}' <<<"${before}")"
done

# The plan: per environment the zone it keeps (or null) and the ones made shared.
plan="$(jq -c --argjson C "${contested}" --argjson B "${before}" '
    . as $Z
    | [ $C | to_entries[] | .key as $e | .value as $zs
        | (if ($B[$e] // null) as $b | $b != null and ($zs | index($b)) != null then {keep: $B[$e], why: "it was its zone before 0018"}
           elif ($zs | index($e)) != null then {keep: $e, why: "it is named like the environment"}
           else {keep: null, why: null} end) as $k
        | { env: $e, zones: $zs, keep: $k.keep, why: $k.why,
            shared: (if $k.keep == null then [] else $zs - [$k.keep] end) }
        | .mgmt = [ .shared[] | select(($Z[.].type // "") == "Management") ] ]' "${ZONES}")"

problems="$(jq -r '.[] |
    if .keep == null then
        "environment \(.env) is named as its own by \(.zones | length) zones (\(.zones | join(", "))), and neither its zone before 0018 nor a zone named \(.env) says which keeps it — make the others shared: network-manager bind <zone> --environment \(.env) --add"
    elif (.mgmt | length) > 0 then
        "environment \(.env) keeps zone \(.keep), which would make the Management zone \(.mgmt | join(", ")) shared — a Management zone never is"
    else empty end' <<<"${plan}")"
if [[ -n "${problems}" ]]; then
    while IFS= read -r p; do echo -e "\033[01;31m[Error]\033[m 0023: ${p}" >&2; done <<<"${problems}"
    stop "refusing to migrate — zones.json is unchanged; a person should look at this"
fi

describe() {
    local verb="$1"
    jq -r '.[] | "\(.env) keeps zone \(.keep) (\(.why)); \(.shared | join(", ")) \(if (.shared | length) == 1 then "becomes a shared service zone" else "become shared service zones" end)"' <<<"${plan}" \
        | while IFS= read -r l; do say "${verb}: ${l}"; done
}

if [[ "${CHECK}" -eq 1 ]]; then
    describe "would repair"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"

tmp="${ZONES}.0023.tmp"
jq --argjson P "${plan}" '
    reduce ($P[] | .env as $e | .shared[] | {zone: ., env: $e}) as $s (.;
        .[$s.zone].environment = [$s.env])' "${ZONES}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite of zones.json failed — it is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten zones.json is not valid JSON — it is unchanged"; }
chmod --reference="${BACKUP_DIR}/zones.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${ZONES}"

describe "repaired"
note "backup: ${BACKUP_DIR}"
