#!/usr/bin/env bash
# test-migration-0020-positions.sh — the fixture test for migration 0020 (#870).
#
# hrossen's racks.json and site.json (position-manager's test fixtures): rack1
# in basement with six devices, the ISP modem loose in basement, Nano HD loose
# in stue, patchpanel1, one cable. Before → after, --check writes nothing,
# applying twice is a no-op, the backup holds racks.json, no site.json leaves
# the rooms without a location, and each refusal leaves every file as it was.
# Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0020-racks-become-positions.sh"
FIX="${CICD}/manager/position-manager/test/fixtures"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
yes() { if eval "$2"; then echo yes; else echo no; fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${FIX}/racks-hrossen.json" && -f "${FIX}/site-hrossen.json" ]] || { echo "  ✗ the hrossen fixtures are not in ${FIX}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0020.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

fresh() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    cp "${FIX}/racks-hrossen.json" "${CFG}/racks.json"
    cp "${FIX}/site-hrossen.json" "${CFG}/site.json"
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0020" bash "${M}" "$@" 2>&1; }
pos() { jq -c "$1" "${CFG}/positions.json"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }

fresh
before="$(jq -c . "${CFG}/racks.json")"
out="$(run --check)"; rc=$?
ck "--check: exit 0"                                   0 "${rc}"
ck "…writes nothing"                                   "${before}" "$(jq -c . "${CFG}/racks.json")"
ck "…no positions.json"                                no "$(yes '' '[[ -e "${CFG}/positions.json" ]]')"
ck "…makes no backup"                                  no "$(yes '' '[[ -e "${CFG}/.migrations/backup/0020" ]]')"
ck "…and says what it would do"                        yes "$(yes '' '[[ "${out}" == *"would: racks.json → positions.json: 8 mount(s) → placements"* && "${out}" == *"would: room(s) basement, stue → location knudanchersvej95 (the primary)"* ]]')"

out="$(run)"; rc=$?
ck "the run succeeds"                                  0 "${rc}"
ck "racks.json is gone"                                no "$(yes '' '[[ -e "${CFG}/racks.json" ]]')"
ck "positions.json is there"                           yes "$(yes '' '[[ -f "${CFG}/positions.json" ]]')"
ck "mounts became placements"                          '[false,8]' "$(pos '[has("mounts"), (.placements | length)]')"
ck "a rack placement keeps its fields"                 "$(jq -c '.mounts.tappaas1' <<<"${before}")" "$(pos '.placements.tappaas1')"
ck "…every one of them"                                "$(jq -c '[.mounts | to_entries[] | select(.value.rack) ] | from_entries' <<<"${before}")" "$(pos '[.placements | to_entries[] | select(.value.rack)] | from_entries')"
ck "a loose one keeps its room, nothing of a rack's"   '{"room":"basement"}' "$(pos '.placements["ISP modem"]')"
ck "…Nano HD loose in stue"                            '{"room":"stue"}' "$(pos '.placements["Nano HD"]')"
ck "…and says what it dropped"                         yes "$(yes '' '[[ "${out}" == *"ISP modem, loose in room basement: its face, height, width dropped"* ]]')"
ck "the rooms are at the primary location"             '{"basement":"knudanchersvej95","stue":"knudanchersvej95"}' "$(pos '.rooms | map_values(.location)')"
ck "…their other fields kept"                          '{"basement":"Basement","stue":"Stue"}' "$(pos '.rooms | map_values(.displayName)')"
ck "racks, devices and cables carried over as they are" "$(jq -c '[.racks, .devices, .cables]' <<<"${before}")" "$(pos '[.racks, .devices, .cables]')"
ck "the keys in the schema's order"                    '["version","rooms","racks","placements","devices","cables"]' "$(jq -c 'keys_unsorted' "${CFG}/positions.json")"
ck "the backup holds racks.json"                       "${before}" "$(jq -c . "${CFG}/.migrations/backup/0020/racks.json")"
ck "site.json is untouched"                            "$(jq -c . "${FIX}/site-hrossen.json")" "$(jq -c . "${CFG}/site.json")"
ck "no temp file left"                                 no "$(yes '' 'compgen -G "${CFG}/*.tmp" >/dev/null')"

after="$(snap)"
out="$(run)"; rc=$?
ck "twice: exit 0"                                     0 "${rc}"
ck "…changes nothing"                                  "${after}" "$(snap)"
ck "…and says so"                                      yes "$(yes '' '[[ "${out}" == *"nothing to migrate"* ]]')"

# position-manager's reading of an unmigrated racks.json is what 0020 writes.
ck "the reader's legacy shape matches (loose: room, faceplate, label, description)" yes "$(yes '' 'grep -q "\"room\", \"faceplate\", \"label\", \"description\"" "${CICD}/lib/ts/src/positions.ts"')"

# No site.json: the rooms keep no location (absent is the primary).
fresh; rm -f "${CFG}/site.json"
out="$(run)"; rc=$?
ck "no site.json: exit 0"                              0 "${rc}"
ck "…the rooms keep no location"                       '[null,null]' "$(pos '[.rooms.basement.location, .rooms.stue.location]')"
ck "…and it is reported"                               yes "$(yes '' '[[ "${out}" == *"keep no location"* ]]')"

# A room that already names a location keeps it.
fresh; jq '.rooms.stue.location = "hareskov"' "${CFG}/racks.json" > "${TMP}/r" && mv "${TMP}/r" "${CFG}/racks.json"
run >/dev/null; ck "a room's own location is kept"     '"hareskov"' "$(pos '.rooms.stue.location')"

# The refusals: each leaves every file as it was.
refuse() {  # <what> <setup command>
    fresh; eval "$2"
    local s; s="$(snap)"
    out="$(run)"; rc=$?
    ck "refused: $1 (exit 1)"                          1 "${rc}"
    ck "…nothing changed"                              "${s}" "$(snap)"
    ck "…no backup"                                    no "$(yes '' '[[ -e "${CFG}/.migrations/backup/0020" ]]')"
}
refuse "racks.json and positions.json both" 'echo "{}" > "${CFG}/positions.json"'
refuse "racks.json not JSON" 'echo "{" > "${CFG}/racks.json"'
refuse "racks.json not an object" 'echo "[]" > "${CFG}/racks.json"'
refuse "mounts not an object" 'jq ".mounts = []" "${CFG}/racks.json" > "${TMP}/r" && mv "${TMP}/r" "${CFG}/racks.json"'
refuse "a mount with a rack and a room" 'jq ".mounts.tappaas1.room = \"stue\"" "${CFG}/racks.json" > "${TMP}/r" && mv "${TMP}/r" "${CFG}/racks.json"'
refuse "a mount with neither" 'jq ".mounts.tappaas1 |= del(.rack)" "${CFG}/racks.json" > "${TMP}/r" && mv "${TMP}/r" "${CFG}/racks.json"'
refuse "a room naming no location" 'jq ".rooms.stue.location = \"mars\"" "${CFG}/racks.json" > "${TMP}/r" && mv "${TMP}/r" "${CFG}/racks.json"'
refuse "site.json still with location" 'jq ". + {location: {country: \"DK\"}}" "${CFG}/site.json" > "${TMP}/s" && mv "${TMP}/s" "${CFG}/site.json"'

# No racks.json at all: nothing to do.
rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no racks.json: exit 0, nothing to do"              "0 yes" "${rc} $(yes '' '[[ "${out}" == *"nothing to migrate"* ]]')"

echo ""
echo "migration 0020: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
