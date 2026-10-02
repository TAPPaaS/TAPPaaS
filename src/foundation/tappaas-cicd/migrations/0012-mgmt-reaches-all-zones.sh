#!/usr/bin/env bash
# 0012-mgmt-reaches-all-zones.sh — mgmt.access-to becomes ["internet", "all"]
#
# Introduced: 2.1 (Wave 2 entry gate).  Required by: #375.
# Touches: config/zones.json (only).
# Reversible: yes — restore config/.migrations/backup/0012/zones.json.
#
# WHY. mgmt, the control plane, must reach every zone (zones.json _README,
# mgmt_exception). It said so with a hand-kept list that every zone add and
# delete had to edit, and any path that forgot left it wrong (#372, #373) — the
# release's own list lacked the IoT zones. The `all` sentinel says it once:
# internet plus every other standard zone (not Disabled, not Overlay or WAN),
# expanded by the controller when it reads the file, so every consumer sees the
# list it stands for.
#
# What changes on the firewall: nothing. mgmt is a Manual zone and gets no
# generated zone rules; the list feeds validation and the pinhole/egress checks,
# which now see every zone instead of the ones someone remembered. The zones the
# old list did not name are reported.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): an access-to that is not a
# list of strings, and a list without `internet` (the sentinel includes it, so
# rewriting would add internet egress nobody asked for).
#
# Usage: 0012-mgmt-reaches-all-zones.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0012}"
ZONES="${CONFIG_DIR}/zones.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0012: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0012: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0012: $*" >&2; exit 1; }

[[ -f "${ZONES}" ]] || { say "no ${ZONES} — nothing to migrate"; exit 0; }
jq empty "${ZONES}" 2>/dev/null || stop "${ZONES} is not valid JSON — refusing to touch it"

shape="$(jq -r 'if (.mgmt | type) != "object" then "absent"
                elif (.mgmt["access-to"] // [] | type) != "array" then "not-a-list"
                elif any(.mgmt["access-to"][]?; type != "string") then "not-strings"
                elif (.mgmt["access-to"] | index("all")) != null then "done"
                else "list" end' "${ZONES}")"
case "${shape}" in
    absent) say "zones.json has no mgmt zone — nothing to migrate"; exit 0 ;;
    done)   say "mgmt.access-to already uses \"all\" — nothing to migrate"; exit 0 ;;
    not-a-list|not-strings)
        stop "mgmt.access-to is $(jq -c '.mgmt["access-to"]' "${ZONES}"), not a list of zone names — a person should look at this" ;;
esac

old="$(jq -c '.mgmt["access-to"]' "${ZONES}")"
jq -e '.mgmt["access-to"] | index("internet") != null' "${ZONES}" >/dev/null \
    || stop "mgmt.access-to ${old} does not list internet; \"all\" includes it, so rewriting would add internet egress — a person should decide"

# Zones the old list did not name — what "all" now covers that it did not.
added="$(jq -r '
    [to_entries[] | select((.key | startswith("_") | not) and (.value | type) == "object"
                           and .key != "mgmt" and .value.state != "Disabled"
                           and ((.value.type // "") | IN("Overlay", "WAN") | not)) | .key] as $zones
    | $zones - .mgmt["access-to"] | join(", ")' "${ZONES}")"
# Names in the old list that are no zone at all (stale) — dropped with it.
stale="$(jq -r '
    [to_entries[] | select((.key | startswith("_") | not) and (.value | type) == "object") | .key] as $zones
    | .mgmt["access-to"] - $zones - ["internet"] | join(", ")' "${ZONES}")"

if [[ "${CHECK}" -eq 1 ]]; then
    say "would rewrite mgmt.access-to ${old} → [\"internet\",\"all\"] in ${ZONES}"
    [[ -z "${added}" ]] || say "  now reached through \"all\": ${added}"
    [[ -z "${stale}" ]] || say "  dropped, not a zone: ${stale}"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${ZONES}" "${BACKUP_DIR}/zones.json" || stop "cannot back up ${ZONES} — refusing to write"

tmp="${ZONES}.0012.tmp"
jq --indent 2 '.mgmt["access-to"] = ["internet", "all"]' "${ZONES}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — ${ZONES} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten zones.json is not valid JSON — ${ZONES} is unchanged"; }
chmod --reference="${BACKUP_DIR}/zones.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${ZONES}"
say "mgmt.access-to ${old} → [\"internet\",\"all\"]"
[[ -z "${added}" ]] || say "  now reached through \"all\": ${added} (mgmt is Manual: no firewall rule changes)"
[[ -z "${stale}" ]] || say "  dropped, not a zone: ${stale}"
note "backup: ${BACKUP_DIR}/zones.json"
