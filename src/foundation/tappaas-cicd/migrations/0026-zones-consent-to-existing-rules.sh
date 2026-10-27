#!/usr/bin/env bash
# 0026-zones-consent-to-existing-rules.sh — zones consent to the cross-zone rules modules already have
#
# Introduced: 2.4.  Required by: #816 (module rules crossing zones need the zones to allow it).
# Touches: config/zones.json (only).
# Reversible: yes — restore config/.migrations/backup/0026/zones.json.
#
# WHY. Since #816 a module rule that crosses zones is refused unless the zones
# allow it: the source zone's access-to names the target, or the target's
# pinhole-allowed-from names the source. Before, the rule was simply written.
# A site whose modules already carried such rules then failed those modules'
# updates, each rolled back (a site on 2026-10-26: deconz, sonos, shelly-fleet,
# voice-fleet into srvHome from iotCloud; synology into mgmt from srvHome), and
# an auto-pinhole the policy refuses is dropped, so its consumer's providers
# report it missing (hassanova into iotCloud).
#
# WHAT IT DOES. For every installed module (a config with zone0, not archived)
# it walks the rules rules-manager judges, with rules-manager's predicate:
#   egress[].to        a zone, or a module peer's zone       our zone -> it
#   ingress[].from     a zone, or a module peer's zone       it -> our zone
#   dependsOn/integratesWith "<p>:<s>"  whose provider ships services/<s>/pinhole.json
#                      with ports (an auto-pinhole)          our zone -> the provider's
# and where the zones do not allow one, adds the source zone to the target's
# pinhole-allowed-from: the consent the site gave by installing the module,
# written down where the policy now looks for it. Each grant is reported with the
# modules that needed it, so the operator can take one back
# (`network-manager modify <zone> --set 'pinhole-allowed-from=[…]'`) — and fix the
# module's rule instead.
#
# What changes on the firewall: nothing by itself. pinhole-allowed-from writes no
# zone rule; it lets each module's own rules be written again, on its update.
#
# NOT GRANTED, reported: ingress from the internet (opening a zone to the internet
# is not a consent to infer), a foundation provider whose pinhole.json says
# "fromZones": "any" (already allowed), peers that are aliases or unknown, and
# zones zones.json does not have.
#
# Usage: 0026-zones-consent-to-existing-rules.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0026}"
ZONES="${CONFIG_DIR}/zones.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0026: $*"; }
warn() { echo -e "\033[33m[Warning]\033[m 0026: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0026: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0026: $*" >&2; exit 1; }

[[ -f "${ZONES}" ]] || { say "no ${ZONES} — nothing to migrate"; exit 0; }
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to touch it"
bad="$(jq -r 'to_entries[] | select((.key | startswith("_") | not) and (.value | type) == "object")
              | select(((.value["access-to"] // []) | type) != "array"
                       or ((.value["pinhole-allowed-from"] // []) | type) != "array"
                       or any((.value["access-to"] // [])[], (.value["pinhole-allowed-from"] // [])[]; type != "string"))
              | .key' "${ZONES}")"
[[ -z "${bad}" ]] || stop "zone(s) $(paste -sd, <<<"${bad}") have an access-to or pinhole-allowed-from that is not a list of names — a person should look at this"

# The installed modules: every config naming a zone0, not archived.
declare -A ZONE_OF=() FILE_OF=()
for f in "${CONFIG_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    case "$(basename "${f}" .json)" in zones|site|configuration|firewall|aliases|sequence-map|module-fields) continue ;; esac
    row="$(jq -r 'select(type == "object" and (.zone0 | type) == "string" and .zone0 != ""
                         and (.status // "") != "archived")
                  | [.vmname // "", .zone0] | @tsv' "${f}" 2>/dev/null)" || continue
    [[ -n "${row}" ]] || continue
    name="$(basename "${f}" .json)"
    ZONE_OF["${name}"]="${row#*$'\t'}"; FILE_OF["${name}"]="${f}"
    vm="${row%%$'\t'*}"
    [[ -n "${vm}" && -z "${ZONE_OF[${vm}]:-}" ]] && ZONE_OF["${vm}"]="${row#*$'\t'}"
done

is_zone() { jq -e --arg z "$1" '(.[$z] | type) == "object"' "${ZONES}" >/dev/null 2>&1; }
allowed() {  # allowed <src> <dst> — rules-manager's _cross_zone_refusal, inverted
    [[ "$1" == "$2" ]] && return 0
    jq -e --arg s "$1" --arg t "$2" '
        ((.[$s]["access-to"] // []) | index($t) != null or index("all") != null)
        or ((.[$t]["pinhole-allowed-from"] // []) | index($s) != null)' "${ZONES}" >/dev/null
}
peer_zone() {  # peer_zone <peer> — a zone name stands for itself, a module for its zone0
    local p="$1"
    case "${p}" in internet|alias:*) return 0 ;; esac
    if is_zone "${p}"; then printf '%s' "${p}"; else printf '%s' "${ZONE_OF[${p}]:-}"; fi
}
provider_of() {  # provider_of <name> <environment> — resolve_provider_module, config side
    local p="$1" env="$2" alt
    if [[ -n "${env}" && -n "${FILE_OF[${p}-${env}]:-}" ]]; then printf '%s' "${p}-${env}"; return; fi
    if [[ -n "${FILE_OF[${p}]:-}" ]]; then printf '%s' "${p}"; return; fi
    case "${p}" in network) alt=firewall ;; firewall) alt=network ;; *) alt="" ;; esac
    [[ -n "${alt}" && -n "${FILE_OF[${alt}]:-}" ]] && printf '%s' "${alt}"
    return 0
}

declare -A GRANT=()   # "src<TAB>dst" -> "module (why), …"
need() {  # need <src> <dst> <module> <why>
    local s="$1" t="$2"
    [[ -n "${s}" && -n "${t}" && "${s}" != "${t}" ]] || return 0
    if ! is_zone "${s}" || ! is_zone "${t}"; then note "$3: ${s} -> ${t} names a zone zones.json lacks — skipped"; return 0; fi
    allowed "${s}" "${t}" && return 0
    local k="${s}"$'\t'"${t}"
    GRANT["${k}"]="${GRANT[${k}]:+${GRANT[${k}]}, }$3 ($4)"
}

for name in "${!FILE_OF[@]}"; do
    f="${FILE_OF[${name}]}"; z="${ZONE_OF[${name}]}"
    env="$(jq -r '.environment // ""' "${f}")"
    while IFS=$'\t' read -r dir peer; do
        [[ -n "${peer}" ]] || continue
        if [[ "${dir}" == in && "${peer}" == internet ]]; then
            # The firewall module is the internet's way in; rules-manager exempts it.
            case "$(jq -r '.vmname // ""' "${f}")" in network|firewall) continue ;; esac
            allowed internet "${z}" || warn "${name}: ingress from the internet into ${z} — not granted; if ${z} should accept it: network-manager modify ${z} --set 'pinhole-allowed-from=[…, \"internet\"]'"
            continue
        fi
        pz="$(peer_zone "${peer}")"
        [[ -n "${pz}" ]] || { note "${name}: ${dir}gress peer '${peer}' is no zone or module — skipped"; continue; }
        if [[ "${dir}" == out ]]; then need "${z}" "${pz}" "${name}" "egress to ${peer}"
        else need "${pz}" "${z}" "${name}" "ingress from ${peer}"; fi
    done < <(jq -r '(.config["network:rules"] // .config["firewall:rules"] // {}) as $fr
                    | ((.egress // $fr.egress // [])[]? | select(type == "object") | ["out", (.to // "")]),
                      ((.ingress // $fr.ingress // [])[]? | select(type == "object") | ["in", (.from // "")])
                    | @tsv' "${f}")
    while read -r dep; do
        [[ "${dep}" == *:* ]] || continue
        prov="$(provider_of "${dep%%:*}" "${env}")"; svc="${dep#*:}"
        [[ -n "${prov}" ]] || continue
        src="$(jq -r '.moduleSource // (.location | strings) // ""' "${FILE_OF[${prov}]}")"
        ph="${src}/services/${svc}/pinhole.json"
        [[ -n "${src}" && -f "${ph}" ]] || continue
        jq -e '(.ports // []) | length > 0' "${ph}" >/dev/null 2>&1 || continue
        if [[ "/${src}/" == */foundation/* ]] && jq -e '.fromZones == "any"' "${ph}" >/dev/null 2>&1; then continue; fi
        need "${z}" "${ZONE_OF[${prov}]}" "${name}" "${dep}"
    done < <(jq -r '(.dependsOn // []) + (.integratesWith // []) | .[]? | strings' "${f}")
done

if [[ "${#GRANT[@]}" -eq 0 ]]; then
    say "every cross-zone rule of the installed modules is already allowed — nothing to migrate"
    exit 0
fi

# One line per grant, in a stable order.
mapfile -t KEYS < <(printf '%s\n' "${!GRANT[@]}" | sort)
report() {
    local k
    for k in "${KEYS[@]}"; do
        say "  $1 ${k%%$'\t'*} to ${k#*$'\t'}.pinhole-allowed-from — for $(sed 's/, /\n/g' <<<"${GRANT[${k}]}" | sort | paste -sd, - | sed 's/,/, /g')"
    done
}

if [[ "${CHECK}" -eq 1 ]]; then
    say "would let zones accept the cross-zone rules installed modules already have (${#KEYS[@]}):"
    report "would add"
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"

pairs="$(for k in "${KEYS[@]}"; do jq -nc --arg s "${k%%$'\t'*}" --arg t "${k#*$'\t'}" '[$s, $t]'; done | jq -sc .)"
tmp="${ZONES}.0026.tmp"
jq --indent 2 --argjson pairs "${pairs}" '
    reduce $pairs[] as [$s, $t] (.; .[$t]["pinhole-allowed-from"] = (((.[$t]["pinhole-allowed-from"] // []) + [$s]) | unique))' \
    "${ZONES}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite failed — ${ZONES} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten zones.json is not valid JSON — ${ZONES} is unchanged"; }
chmod --reference="${BACKUP_DIR}/zones.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${ZONES}"
say "zones now accept the cross-zone rules installed modules already have (${#KEYS[@]}):"
report "added"
say "  to take one back: network-manager modify <zone> --set 'pinhole-allowed-from=[…]', then change that module's rule"
note "backup: ${BACKUP_DIR}/zones.json"
