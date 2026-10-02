#!/usr/bin/env bash
# test-migration-0012-mgmt-all.sh — the fixture test for migration 0012 (#375).
#
# before → after, --check writes nothing, applying twice is a no-op, the backup
# holds the pre-image, the zones the old list missed are reported, and a shape
# the migration does not recognise stops it with zones.json untouched.
# Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0012-mgmt-reaches-all-zones.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0012.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# A zones.json whose mgmt.access-to is the given value, beside zones the
# migration must leave exactly as they are.
zones() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    jq -n --argjson a "$1" '{
        _README: {mgmt_exception: "text"},
        mgmt:    {state: "Manual", tier: 0, "access-to": $a},
        home:    {state: "Active", "access-to": ["internet"]},
        iotCams: {state: "Active", isolated: true, "access-to": []},
        gone:    {state: "Disabled", "access-to": []},
        admin:   {type: "Overlay", state: "Manual", "access-to": ["mgmt"]}
    }' > "${CFG}/zones.json"
}
run()  { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0012" bash "${M}" "$@" 2>&1; }
acc()  { jq -c '.mgmt["access-to"]' "${CFG}/zones.json"; }
rest() { jq -c 'del(.mgmt["access-to"])' "${CFG}/zones.json"; }

zones '["internet","home","oldzone"]'
others="$(rest)"
out="$(run)"; rc=$?
ck "an explicit list → [internet, all]"          '["internet","all"]' "$(acc)"
ck "…the run succeeds"                           0 "${rc}"
ck "…the zone it missed is reported"             yes "$(has "${out}" 'now reached through "all": iotCams')"
ck "…a Disabled zone is not among them"          no "$(has "${out}" "gone")"
ck "…nor an overlay"                             no "$(has "${out}" "admin")"
ck "…a name that is no zone is reported dropped" yes "$(has "${out}" "dropped, not a zone: oldzone")"
ck "…everything else untouched"                  "${others}" "$(rest)"
ck "…the pre-image is backed up"                 '["internet","home","oldzone"]' "$(jq -c '.mgmt["access-to"]' "${CFG}/.migrations/backup/0012/zones.json")"
before="$(cat "${CFG}/zones.json")"; out="$(run)"
ck "a second run changes nothing"                "${before}" "$(cat "${CFG}/zones.json")"
ck "…and says so"                                yes "$(has "${out}" "already uses")"

zones '["internet","home"]'
out="$(run --check)"
ck "--check writes nothing"                      '["internet","home"]' "$(acc)"
ck "…and says what it would do"                  yes "$(has "${out}" 'would rewrite mgmt.access-to ["internet","home"]')"
ck "…no backup is made"                          no "$([[ -e "${CFG}/.migrations" ]] && echo yes || echo no)"

zones '["home"]'
run >/dev/null; rc=$?
ck "no internet in the list: refused"            1 "${rc}"
ck "…zones.json untouched"                       '["home"]' "$(acc)"

zones '"home"'
run >/dev/null; rc=$?
ck "not a list: refused"                         "1 \"home\"" "${rc} $(acc)"

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '{"home":{"state":"Active"}}' > "${CFG}/zones.json"
run >/dev/null; rc=$?
ck "no mgmt zone: nothing to do"                 "0 {\"home\":{\"state\":\"Active\"}}" "${rc} $(jq -c . "${CFG}/zones.json")"

echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
