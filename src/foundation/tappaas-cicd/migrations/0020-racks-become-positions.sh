#!/usr/bin/env bash
# 0020-racks-become-positions.sh — racks.json becomes positions.json: placements, rooms in a location
#
# Introduced: 2.3.  Required by: #870 (ADR-036 D3).
# Touches: config/racks.json → config/positions.json (only); reads config/site.json.
# Reversible: yes — restore config/.migrations/backup/0020/racks.json and remove
#   config/positions.json.
#
# WHY. rack-manager became position-manager, and its file says what it holds:
# where each device is placed inside the site's locations. A room is in a
# location of site.json (migration 0019 made them); a device stands in a rack
# at its units or loose in a room.
#
# What it writes: config/positions.json from config/racks.json —
#   - `mounts{}` becomes `placements{}`, keyed by device as before: one in a
#     rack keeps rack, u, height, width, slot, face, faceplate, label and
#     description; one loose in a room keeps room, faceplate, label and
#     description (its height, width and face drew nothing its plate does not
#     give, and are reported);
#   - every room without a `location` gets site.json's `primaryLocation`; with
#     no site.json yet the rooms keep none — absent is the primary — and that
#     is reported;
#   - racks, devices and cables are carried over as they are;
#   - then racks.json is removed: its copy in the backup is the rollback.
# position-manager reads racks.json until this has run and refuses to change it.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3), changing nothing:
#   - racks.json and positions.json both present (a person decides which one is
#     the site's);
#   - a racks.json that is not a JSON object, or whose mounts are not an object;
#   - a mount with both a rack and a room, or neither;
#   - a room whose `location` names no location of site.json;
#   - a site.json that still carries the retired `location` (0019 has not run).
#
# Usage: 0020-racks-become-positions.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0020}"
RACKS="${CONFIG_DIR}/racks.json"
POSITIONS="${CONFIG_DIR}/positions.json"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0020: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0020: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0020: $*" >&2; exit 1; }

[[ -f "${RACKS}" ]] || { say "no ${RACKS} — nothing to migrate"; exit 0; }
[[ -e "${POSITIONS}" ]] && stop "both ${RACKS} and ${POSITIONS} exist — a person decides which one is the site's (move the other away)"
jq empty "${RACKS}" 2>/dev/null || stop "${RACKS} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${RACKS}")" == "object" ]] || stop "${RACKS} is not a JSON object — a person should look at this"

# The site's locations: their names and the primary one. No site.json: none.
site='{}'
if [[ -f "${SITE}" ]]; then
    jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to guess its locations"
    site="$(jq -c . "${SITE}")"
fi
jq -e 'type == "object" and has("location") and (.location | type) == "object"' <<<"${site}" >/dev/null \
    && stop "site.json still carries the retired location — migration 0019 makes it locations{} first"

# The plan: the new document, what is reported, and every reason to stop.
plan="$(jq --argjson site "${site}" '
    ($site.primaryLocation // null) as $primary
    | ($site.locations // {} | keys) as $names
    | . as $d
    | (.mounts // {}) as $mounts
    | [ if ($mounts | type) != "object" then "mounts is not an object" else empty end,
        ( $mounts | to_entries[]? | select((.value | type) != "object") | "mount \(.key) is not an object" ),
        ( $mounts | to_entries[]? | select((.value | type) == "object")
          | select((.value.rack != null) == (.value.room != null))
          | "mount \(.key) has \(if .value.rack != null then "both a rack and a room" else "neither a rack nor a room" end)" ),
        ( (.rooms // {}) | to_entries[]? | .value.location as $l | select($l != null and ($names | index($l) | not))
          | "room \(.key) names location \($l), which site.json does not have" )
      ] as $refusals
    | if ($refusals | length) > 0 then {refusals: $refusals} else
      ( $mounts | with_entries(
          if .value.rack != null then .
          else .value |= with_entries(select(.key == "room" or .key == "faceplate" or .key == "label" or .key == "description")) end
        ) ) as $placements
      | ( $mounts | to_entries | map(select(.value.rack == null and ((.value | keys) - ["room", "faceplate", "label", "description"] | length) > 0))
          | map("\(.key), loose in room \(.value.room): its \((.value | keys) - ["room", "faceplate", "label", "description"] | join(", ")) dropped (its plate gives its size)") ) as $reduced
      | ( (.rooms // {}) | to_entries | map(select(.value.location == null)) | map(.key) ) as $unlocated
      | {
          refusals: [],
          doc: (
            { version: 1 }
            + (if $d.rooms != null then { rooms: ($d.rooms | map_values(if .location == null and $primary != null then . + { location: $primary } else . end)) } else {} end)
            + (if $d.racks != null then { racks: $d.racks } else {} end)
            + (if $d.mounts != null then { placements: $placements } else {} end)
            + (if $d.devices != null then { devices: $d.devices } else {} end)
            + (if $d.cables != null then { cables: $d.cables } else {} end)
            + ($d | del(.version, .rooms, .racks, .mounts, .devices, .cables))
          ),
          report: (
            [ "racks.json → positions.json: \($mounts | length) mount(s) → placements" ]
            + $reduced
            + ( if ($unlocated | length) == 0 then []
                elif $primary != null then [ "room(s) \($unlocated | join(", ")) → location \($primary) (the primary)" ]
                else [ "room(s) \($unlocated | join(", ")) keep no location: site.json names no primary yet, and none is the primary" ] end )
          )
        } end
' "${RACKS}")" || stop "could not read ${RACKS} — it is unchanged"

if [[ "$(jq '.refusals | length' <<<"${plan}")" -gt 0 ]]; then
    jq -r '.refusals[]' <<<"${plan}" | while IFS= read -r l; do echo -e "\033[01;31m[Error]\033[m 0020: ${l}" >&2; done
    stop "nothing was changed — a person should look at ${RACKS}"
fi

if [[ "${CHECK}" -eq 1 ]]; then
    jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "would: ${l}"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${RACKS}" "${BACKUP_DIR}/racks.json" || stop "cannot back up ${RACKS} — refusing to write"

# Through a temp beside it, checked, then moved into place; racks.json goes
# only once positions.json is there.
tmp="${POSITIONS}.0020.tmp"
jq '.doc' <<<"${plan}" > "${tmp}" || { rm -f "${tmp}"; stop "writing ${POSITIONS} failed — ${RACKS} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the new ${POSITIONS} is not valid JSON — ${RACKS} is unchanged"; }
chmod --reference="${RACKS}" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${POSITIONS}"
rm -f "${RACKS}"

jq -r '.report[]' <<<"${plan}" | while IFS= read -r l; do say "${l}"; done
note "backup: ${BACKUP_DIR}"
