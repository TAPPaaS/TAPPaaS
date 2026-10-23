#!/usr/bin/env bash
# test-migration-0019-locations.sh — the fixture test for migration 0019 (#869).
#
# hrossen's site.json (the topology fixture's) and its buddy rasmus: before →
# after, --check writes nothing, applying twice is a no-op, the backup holds the
# pre-images, a second peer at the same place shares its location, a peer at the
# site's own place names the primary, a name clash gets -2, and each refusal
# leaves every file as it was. Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0019-site-location-becomes-locations.sh"
HROSSEN="${CICD}/manager/network-manager/test/fixtures/topology-hrossen/site.json"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
yes() { if eval "$2"; then echo yes; else echo no; fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${HROSSEN}" ]] || { echo "  ✗ ${HROSSEN} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0019.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

# hrossen: the site, its buddy rasmus (remote, DK/Hareskov), a receive peer that
# records no place, and a module config the migration must not touch.
fresh() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    cp "${HROSSEN}" "${CFG}/site.json"
    echo '{"name":"rasmus","type":"remote","authId":"rasmus@pbs","namespace":"","propagate":false,"physicalLocation":{"country":"DK","city":"Hareskov"},"tunnel":{"role":"serve","net":"10.255.2.0/30","mtu":1420,"listenPort":51830}}' > "${CFG}/remote-rasmus.json"
    echo '{"name":"nas","type":"receive","namespace":"receive/nas"}' > "${CFG}/receive-nas.json"
    echo '{"vmname":"nextcloud","moduleSource":"/home/tappaas/TAPPaaS/src/x/nextcloud"}' > "${CFG}/nextcloud.json"
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0019" bash "${M}" "$@" 2>&1; }
site() { jq -c "$1" "${CFG}/site.json"; }
peer() { jq -c "$2" "${CFG}/$1"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }

fresh
before_site="$(jq -c . "${CFG}/site.json")"; before_rasmus="$(cat "${CFG}/remote-rasmus.json")"
out="$(run --check)"; rc=$?
ck "--check: exit 0"                                0 "${rc}"
ck "…writes nothing"                                "${before_site}" "$(site .)"
ck "…makes no backup"                               no "$(yes '' '[[ -e "${CFG}/.migrations/backup/0019" ]]')"
ck "…and says what it would do"                     yes "$(yes '' '[[ "${out}" == *"would: site.json location → locations.rodovre"* && "${out}" == *"would: remote-rasmus.json: physicalLocation → a new location hareskov"* ]]')"

out="$(run)"; rc=$?
ck "the run succeeds"                               0 "${rc}"
ck "location is gone"                               false "$(site 'has("location")')"
ck "the primary is named from the city"             '"rodovre"' "$(site .primaryLocation)"
ck "…with the place and the timezone"               '{"displayName":"Rodovre","country":"DK","city":"Rodovre","timezone":"Europe/Copenhagen"}' "$(site .locations.rodovre)"
ck "locale and keyboard are site-wide"              '["en_US","dk"]' "$(site '[.locale, .keyboard]')"
ck "the buddy's place is a remote location"         '{"displayName":"Hareskov","kind":"remote","country":"DK","city":"Hareskov"}' "$(site .locations.hareskov)"
ck "…the peer names it"                             '"hareskov"' "$(peer remote-rasmus.json .location)"
ck "…and carries no physicalLocation"               false "$(peer remote-rasmus.json 'has("physicalLocation")')"
ck "…its other fields untouched"                    "$(jq -c 'del(.physicalLocation)' <<<"${before_rasmus}")" "$(peer remote-rasmus.json 'del(.location)')"
ck "the rest of site.json is untouched"             "$(jq -c 'del(.location)' <<<"${before_site}")" "$(site 'del(.locations, .primaryLocation, .locale, .keyboard)')"
ck "a peer with no place is left alone"             '{"name":"nas","type":"receive","namespace":"receive/nas"}' "$(peer receive-nas.json .)"
ck "the backup holds the site's pre-image"          "${before_site}" "$(jq -c . "${CFG}/.migrations/backup/0019/site.json")"
ck "…and the peer's"                                "${before_rasmus}" "$(cat "${CFG}/.migrations/backup/0019/remote-rasmus.json")"
ck "…and nothing it did not change"                 no "$(yes '' '[[ -e "${CFG}/.migrations/backup/0019/receive-nas.json" ]]')"
ck "the report names each rewrite"                  yes "$(yes '' '[[ "${out}" == *"locations.rodovre, the primary location (Rodovre, DK)"* && "${out}" == *"a new location hareskov, kind remote (Hareskov, DK)"* ]]')"

state="$(snap)"; out="$(run)"; rc=$?
ck "a second run changes nothing"                   "${state}" "$(snap)"
ck "…exits 0"                                       0 "${rc}"
ck "…and says so"                                   yes "$(yes '' '[[ "${out}" == *"nothing to migrate"* ]]')"

# The site named from its building; a second buddy at the same place shares the
# location; one at the site's own place names the primary; a name clash.
fresh
jq '.location.building = "Knud Anchers Vej 95" | .location.city = "Rødovre"' "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"
echo '{"remoteHost":"h1","physicalLocation":{"country":"dk","city":" hareskov "}}' > "${CFG}/pull-rasmus.json"
echo '{"remoteHost":"h2","physicalLocation":{"country":"DK","city":"Rødovre","building":"knud anchers vej 95"}}' > "${CFG}/pull-home.json"
echo '{"authId":"x@pbs","physicalLocation":{"country":"SE","city":"Hareskov"}}' > "${CFG}/remote-sweden.json"
echo '{"authId":"y@pbs","physicalLocation":{"country":"NO"}}' > "${CFG}/remote-olaf.json"
run >/dev/null; rc=$?
ck "exit 0"                                         0 "${rc}"
ck "the primary is named from the building"         '"knud-anchers-vej-95"' "$(site .primaryLocation)"
ck "…its address the building as written"           '["Knud Anchers Vej 95","Rødovre"]' "$(site '.locations["knud-anchers-vej-95"] | [.address, .city]')"
ck "a peer at the site's own place names the primary" '"knud-anchers-vej-95"' "$(peer pull-home.json .location)"
ck "two peers at one place share a location"        '["hareskov","hareskov"]' "$(jq -sc 'map(.location)' "${CFG}/pull-rasmus.json" "${CFG}/remote-rasmus.json")"
ck "another place of the same name gets -2"         '"hareskov-2"' "$(peer remote-sweden.json .location)"
ck "…as its own location"                           '"SE"' "$(site '.locations["hareskov-2"].country')"
ck "a peer with a country only is named after itself" '{"kind":"remote","country":"NO"}' "$(site .locations.olaf)"
ck "the locations, once each"                       '["hareskov","hareskov-2","knud-anchers-vej-95","olaf"]' "$(site '.locations | keys')"

# A site whose primary has no timezone recorded, positions kept.
fresh
jq '.location = {"country":"dk","latitude":55.68,"longitude":12.46}' "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"
run >/dev/null
ck "no city or building: named from the site code"  '"rossen"' "$(site .primaryLocation)"
ck "…the country upper-case, the position kept"     '{"country":"DK","latitude":55.68,"longitude":12.46}' "$(site .locations.rossen)"

# Locale and keyboard already at the top level win, and the difference is said.
fresh
jq '.keyboard = "us"' "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"
out="$(run)"
ck "a top-level keyboard wins"                      '"us"' "$(site .keyboard)"
ck "…and the dropped one is reported"               yes "$(yes '' '[[ "${out}" == *"keyboard: site.json already says us; location.keyboard dk is dropped"* ]]')"

# A site already migrated: only its peers.
fresh
jq 'del(.location) + {locations: {home: {country: "DK", city: "Hareskov", timezone: "UTC"}}, primaryLocation: "home"}' "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"
run >/dev/null
ck "a migrated site: a peer at its place names it"  '"home"' "$(peer remote-rasmus.json .location)"
ck "…and no location is added"                      '["home"]' "$(site '.locations | keys')"

# Refusals: every file as it was, exit 1.
refused() {  # <what> <setup>
    fresh; eval "$2"; local s; s="$(snap)"
    run >/dev/null; local rc=$?
    ck "$1: refused (rc 1)"                         1 "${rc}"
    ck "…every file untouched"                      "${s}" "$(snap)"
}
refused "a location without a country"   'jq ".location |= del(.country)" "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"'
refused "a location that is no object"   'jq ".location = \"Rodovre\"" "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"'
refused "location beside locations"      'jq ".locations = {}" "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"'
refused "a primary naming no location"   'jq "del(.location) + {locations: {}, primaryLocation: \"x\"}" "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"'
refused "a peer's place without a country" 'echo "{\"physicalLocation\":{\"city\":\"Oslo\"}}" > "${CFG}/pull-x.json"'
refused "a peer with location and physicalLocation" 'echo "{\"location\":\"x\",\"physicalLocation\":{\"country\":\"NO\"}}" > "${CFG}/pull-x.json"'
refused "a peer naming a location the site lacks" 'echo "{\"location\":\"atlantis\"}" > "${CFG}/pull-x.json"'

rm -rf "${CFG}"; mkdir -p "${CFG}"; echo '["x"]' > "${CFG}/site.json"
run >/dev/null; rc=$?
ck "a site.json that is no object: refused (rc 1)"  1 "${rc}"
ck "…and untouched"                                 '["x"]' "$(jq -c . "${CFG}/site.json")"

rm -rf "${CFG}"; mkdir -p "${CFG}"
run >/dev/null; rc=$?
ck "no site.json: nothing to do (rc 0)"             0 "${rc}"

echo ""
echo "  test-migration-0019: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
