#!/usr/bin/env bash
# 0016-zones-get-ipv6-subnets.sh — every zone that can carry IPv6 gets an ipv6Subnet number
#
# Introduced: 2.3.  Required by: ADR-030 D4 (#26).
# Touches: config/zones.json (only).
# Reversible: yes — restore config/.migrations/backup/0016/zones.json.
#
# WHY. ADR-030 gives each zone an IPv6 network: a /64 inside the site's first
# /56, numbered by the zone's `ipv6Subnet` (0-255). New zones get the number from
# `network-manager add`, and the template's zones carry it; zones that already
# exist on a site do not. This stamps them once, by the same rule `add` uses: the
# VLAN tag read as hex where that fits (VLAN 310 -> 0x31 = 49), else the lowest
# free number. Zones are taken in VLAN-tag order, so the result is the same on
# every run of every site with the same zones.
#
# The number alone gives a zone no IPv6: that needs `site.json` `ipv6: true` and
# a WAN prefix (ADR-030 D1-D3). An operator who wants a zone IPv4-only removes it:
#     network-manager modify <zone> --unset ipv6Subnet
#
# Skipped: Management, Overlay and WAN zones (they never carry IPv6), and zones
# that already have a number.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a zones.json that is not
# JSON, an existing ipv6Subnet that is not an integer 0-255, and one number
# shared by two zones.
#
# Usage: 0016-zones-get-ipv6-subnets.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0016}"
ZONES="${CONFIG_DIR}/zones.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0016: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0016: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0016: $*" >&2; exit 1; }

[[ -f "${ZONES}" ]] || { say "no ${ZONES} — nothing to migrate"; exit 0; }
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to guess"

# Real zones: an object under a key not starting with "_", with a state or a vlantag.
ZONE_ENTRIES='to_entries[] | select(.key | startswith("_") | not)
              | select(.value | type == "object") | select(.value | has("state") or has("vlantag"))'

# The numbers already taken — and the checks that keep them trustworthy.
bad="$(jq -r "${ZONE_ENTRIES} | select(.value | has(\"ipv6Subnet\"))
              | select((.value.ipv6Subnet | type) != \"number\" or .value.ipv6Subnet != (.value.ipv6Subnet | floor)
                       or .value.ipv6Subnet < 0 or .value.ipv6Subnet > 255) | .key" "${ZONES}")"
[[ -z "${bad}" ]] || stop "ipv6Subnet is not an integer 0-255 on: ${bad//$'\n'/, } — a person should look at this"
dupes="$(jq -r "[${ZONE_ENTRIES} | select(.value | has(\"ipv6Subnet\")) | .value.ipv6Subnet]
                | group_by(.) | map(select(length > 1) | .[0]) | .[]" "${ZONES}")"
[[ -z "${dupes}" ]] || stop "ipv6Subnet ${dupes//$'\n'/, } is shared by more than one zone — a person should look at this"

declare -A used=()
while IFS= read -r n; do [[ -n "${n}" ]] && used["${n}"]=1; done \
    < <(jq -r "${ZONE_ENTRIES} | .value.ipv6Subnet // empty" "${ZONES}")

# Zones to stamp, in VLAN-tag order: "<name> <vlantag>".
plan=()
while read -r name vlan; do
    [[ -n "${name}" ]] || continue
    typeId=$(( vlan / 100 )); sub=$(( vlan % 100 ))
    n=""
    if (( sub % 10 == 0 && typeId < 16 )); then
        readable=$(( typeId * 16 + sub / 10 ))
        [[ -z "${used[${readable}]:-}" ]] && n="${readable}"
    fi
    if [[ -z "${n}" ]]; then
        for (( i = 1; i <= 255; i++ )); do
            [[ -z "${used[${i}]:-}" ]] && { n="${i}"; break; }
        done
    fi
    [[ -n "${n}" ]] || stop "no free IPv6 subnet number left for ${name} — 255 zones already have one"
    used["${n}"]=1
    plan+=("${name} ${n}")
done < <(jq -r "[${ZONE_ENTRIES}
                 | select((.value.type // \"\") as \$t | [\"Management\", \"Overlay\", \"WAN\"] | index(\$t) | not)
                 | select(.value | has(\"ipv6Subnet\") | not)]
                | sort_by(.value.vlantag // 0) | .[] | \"\(.key) \(.value.vlantag // 0)\"" "${ZONES}")

if [[ ${#plan[@]} -eq 0 ]]; then
    say "every zone that can carry IPv6 has an ipv6Subnet — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    for p in "${plan[@]}"; do
        say "would give zone ${p%% *} ipv6Subnet ${p##* } ($(printf '0x%02x' "${p##* }"))"
    done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"

filter='.'
for p in "${plan[@]}"; do
    filter+=" | .[\"${p%% *}\"].ipv6Subnet = ${p##* }"
done
tmp="${ZONES}.0016.tmp"
jq "${filter}" "${ZONES}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite failed — zones.json is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten zones.json is not valid JSON — it is unchanged"; }
chmod --reference="${BACKUP_DIR}/zones.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${ZONES}"
for p in "${plan[@]}"; do
    say "zone ${p%% *}: ipv6Subnet ${p##* } ($(printf '0x%02x' "${p##* }")) — to keep it IPv4-only: network-manager modify ${p%% *} --unset ipv6Subnet"
done
note "backup: ${BACKUP_DIR}"
