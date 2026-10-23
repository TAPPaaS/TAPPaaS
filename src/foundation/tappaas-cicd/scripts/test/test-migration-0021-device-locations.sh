#!/usr/bin/env bash
# test-migration-0021-device-locations.sh — the fixture test for migration 0021 (#871).
#
# hrossen's config (fixtures/0021-hrossen: site.json with knudanchersvej95, the
# primary, and hareskov; the pvehost instances tappaas1-3 with no place; the
# switch configuration, whose switches and AP carry an empty or null location)
# plus synthetic machines: a satellite in Helsinki, a debianhost at the
# primary's address, one with an empty physicalLocation; and switches whose
# location is text, a name, or text their description already says. Before →
# after, --check writes nothing, applying twice is a no-op, the backup holds
# what it rewrote, and each refusal leaves every file as it was. Test 9z
# sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0021-device-locations.sh"
FIX="${HERE}/fixtures/0021-hrossen"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
yes() { if eval "$2"; then echo yes; else echo no; fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${FIX}/site.json" ]] || { echo "  ✗ the hrossen fixtures are not in ${FIX}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0021.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"
SAT="/home/tappaas/TAPPaaS/src/foundation/satellite"
DH="/home/tappaas/TAPPaaS/src/foundation/debianhost"

fresh() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    cp "${FIX}"/*.json "${CFG}/"
    echo '{"kind":"machine","moduleSource":"'"${SAT}"'","address":"37.27.5.237","roles":["reverse-proxy","backup"],"physicalLocation":{"country":"fi","city":"Helsinki"}}' > "${CFG}/satellite-hel1.json"
    echo '{"kind":"machine","moduleSource":"'"${DH}"'","address":"10.0.0.51","physicalLocation":{"country":"DK","city":" rodovre ","building":"knudanchersvej95"}}' > "${CFG}/nas.json"
    echo '{"kind":"machine","moduleSource":"'"${DH}"'","address":"10.0.0.52","physicalLocation":{}}' > "${CFG}/printer-host.json"
    echo '{"kind":"vm","moduleSource":"/x/nextcloud","physicalLocation":{"country":"DK"}}' > "${CFG}/nextcloud.json"
    jq '.switches["crs-a"].location = "Rack 1, top" | .switches["crs-b"].location = "hareskov"
        | .switches["crs-b"].description = "the cabin"
        | .switches["USW Pro XG 10 PoE"].description = "basement rack 1" | .switches["USW Pro XG 10 PoE"].location = "Basement Rack 1"
        | .accessPoints["Nano HD"].location = "Loft"' "${FIX}/switch-configuration-desired.json" > "${CFG}/switch-configuration-desired.json"
    jq '.switches["crs-a"].location = "Rack 1, top"' "${FIX}/switch-configuration-actual.json" > "${CFG}/switch-configuration-actual.json"
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0021" bash "${M}" "$@" 2>&1; }
cfg() { jq -c "$2" "${CFG}/$1"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }

# ── hrossen as it is: the empty and null locations go, nothing else ──
rm -rf "${CFG}"; mkdir -p "${CFG}"; cp "${FIX}"/*.json "${CFG}/"
out="$(run)"; rc=$?
ck "hrossen's config: exit 0"                          0 "${rc}"
ck "…its pvehosts untouched (they record no place)"    "$(jq -c . "${FIX}/tappaas1.json")" "$(cfg tappaas1.json .)"
ck "…site.json untouched"                              "$(jq -c . "${FIX}/site.json")" "$(cfg site.json .)"
ck "…the empty and null locations gone"                '[false,false,false,false]' "$(cfg switch-configuration-desired.json '[(.switches[] | has("location")), (.accessPoints[] | has("location"))]')"
ck "…in actual too"                                    '[false,false,false]' "$(cfg switch-configuration-actual.json '[.switches[] | has("location")]')"
ck "…everything else as it was"                        "$(jq -c 'del(.switches[].location, .accessPoints[].location)' "${FIX}/switch-configuration-desired.json")" "$(cfg switch-configuration-desired.json .)"
ck "…and a second run has nothing to do"               yes "$(yes '' '[[ "$(run)" == *"nothing to migrate"* ]]')"

# ── the synthetic estate ──
fresh
before="$(snap)"
out="$(run --check)"; rc=$?
ck "--check: exit 0"                                   0 "${rc}"
ck "…writes nothing"                                   "${before}" "$(snap)"
ck "…makes no backup"                                  no "$(yes '' '[[ -e "${CFG}/.migrations/backup/0021" ]]')"
ck "…and says what it would do"                        yes "$(yes '' '[[ "${out}" == *"would: satellite-hel1.json: physicalLocation → a new location helsinki, kind remote (Helsinki, FI)"* && "${out}" == *"would: nas.json: at location knudanchersvej95"* ]]')"

out="$(run)"; rc=$?
ck "the run succeeds"                                  0 "${rc}"
ck "a satellite elsewhere: a new location, named"      '"helsinki"' "$(cfg satellite-hel1.json .location)"
ck "…of kind remote, at its place"                     '{"displayName":"Helsinki","kind":"remote","country":"FI","city":"Helsinki"}' "$(cfg site.json '.locations.helsinki')"
ck "…its physicalLocation gone, the rest kept"         '{"kind":"machine","moduleSource":"'"${SAT}"'","address":"37.27.5.237","roles":["reverse-proxy","backup"]}' "$(cfg satellite-hel1.json 'del(.location)')"
ck "a machine at the primary's place: the primary"     '"knudanchersvej95"' "$(cfg nas.json .location)"
ck "an empty physicalLocation just goes"               '{"kind":"machine","moduleSource":"'"${DH}"'","address":"10.0.0.52"}' "$(cfg printer-host.json .)"
ck "a guest is not a machine: untouched"               '{"country":"DK"}' "$(cfg nextcloud.json .physicalLocation)"
ck "the primary is where it was"                       '"knudanchersvej95"' "$(cfg site.json .primaryLocation)"
ck "…and the other locations as they were"             "$(jq -c '.locations' "${FIX}/site.json")" "$(cfg site.json '.locations | del(.helsinki)')"
ck "a switch's text: its description"                  '{"description":"Rack 1, top"}' "$(cfg switch-configuration-desired.json '.switches["crs-a"] | {location, description} | with_entries(select(.value != null))')"
ck "…in actual too"                                    '{"description":"Rack 1, top"}' "$(cfg switch-configuration-actual.json '.switches["crs-a"] | {location, description} | with_entries(select(.value != null))')"
ck "a switch naming a location keeps it"               '{"location":"hareskov","description":"the cabin"}' "$(cfg switch-configuration-desired.json '.switches["crs-b"] | {location, description}')"
ck "text the description already says: not twice"      '{"description":"basement rack 1"}' "$(cfg switch-configuration-desired.json '.switches["USW Pro XG 10 PoE"] | {location, description} | with_entries(select(.value != null))')"
ck "an AP's text: its description"                     '{"description":"Loft"}' "$(cfg switch-configuration-desired.json '.accessPoints["Nano HD"] | {location, description} | with_entries(select(.value != null))')"
ck "…its SSIDs and uplink kept"                        "$(jq -c '.accessPoints["Nano HD"] | del(.location)' "${FIX}/switch-configuration-desired.json")" "$(cfg switch-configuration-desired.json '.accessPoints["Nano HD"] | del(.description)')"
ck "…and the ports of every switch"                    "$(jq -c '[.switches[].ports]' "${FIX}/switch-configuration-desired.json")" "$(cfg switch-configuration-desired.json '[.switches[].ports]')"
ck "…and says what it moved"                           yes "$(yes '' '[[ "${out}" == *"switch crs-a: location \"Rack 1, top\" names no location — kept as its description"* && "${out}" == *"access point Nano HD: location \"Loft\""* ]]')"
ck "the backup holds what it rewrote"                  "$(jq -c '.physicalLocation' <<<'{"physicalLocation":{"country":"fi","city":"Helsinki"}}')" "$(jq -c .physicalLocation "${CFG}/.migrations/backup/0021/satellite-hel1.json")"
ck "…site.json and the switch configuration too"       yes "$(yes '' '[[ -f "${CFG}/.migrations/backup/0021/site.json" && -f "${CFG}/.migrations/backup/0021/switch-configuration-desired.json" && -f "${CFG}/.migrations/backup/0021/switch-configuration-actual.json" ]]')"
ck "no temp file left"                                 no "$(yes '' 'compgen -G "${CFG}/*.tmp" >/dev/null')"

after="$(snap)"
out="$(run)"; rc=$?
ck "twice: exit 0"                                     0 "${rc}"
ck "…changes nothing"                                  "${after}" "$(snap)"
ck "…and says so"                                      yes "$(yes '' '[[ "${out}" == *"nothing to migrate"* ]]')"

# Two machines at one new place share one location; a taken name gets -2.
fresh
echo '{"kind":"machine","physicalLocation":{"country":"FI","city":"helsinki"}}' > "${CFG}/satellite-hel2.json"
echo '{"kind":"machine","physicalLocation":{"country":"SE","city":"Hareskov"}}' > "${CFG}/sweden.json"
run >/dev/null
ck "two machines at one place share a location"        '["helsinki","helsinki"]' "$(jq -sc 'map(.location)' "${CFG}/satellite-hel1.json" "${CFG}/satellite-hel2.json")"
ck "a name another place has gets -2"                  '"hareskov-2"' "$(cfg sweden.json .location)"

# What lib/ts locations.ts's readers see is what 0021 wrote: a name, no path.
ck "every machine names a location of the site"        '[]' "$(jq -sc '.[0].locations as $l | .[1:] | map(select(.location != null and ($l[.location] == null)))' "${CFG}/site.json" "${CFG}"/satellite-*.json "${CFG}/nas.json" "${CFG}/sweden.json")"

# ── refusals: each leaves every file as it was ──
refused() {  # <what> <setup>
    fresh; eval "$2"; local b; b="$(snap)"
    local o; o="$(run)"; local r=$?
    ck "refused: $1 (exit 1)"                          1 "${r}"
    ck "…nothing written"                              "${b}" "$(snap)"
}
refused "a site.json without locations"        'jq "del(.locations, .primaryLocation) + {location: {country: \"DK\"}}" "${CFG}/site.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/site.json"'
refused "a machine's place without a country"  'echo "{\"kind\":\"machine\",\"physicalLocation\":{\"city\":\"Oslo\"}}" > "${CFG}/x.json"'
refused "a machine with location and physicalLocation" 'echo "{\"kind\":\"machine\",\"location\":\"hareskov\",\"physicalLocation\":{\"country\":\"NO\"}}" > "${CFG}/x.json"'
refused "a machine whose location is a path"   'echo "{\"kind\":\"machine\",\"location\":\"/src/foundation/debianhost\",\"physicalLocation\":{\"country\":\"NO\"}}" > "${CFG}/x.json"'
refused "a switch whose location is not text"  'jq ".switches[\"crs-a\"].location = {country: \"DK\"}" "${CFG}/switch-configuration-desired.json" > "${CFG}/s" && mv "${CFG}/s" "${CFG}/switch-configuration-desired.json"'

echo ""
echo "test-migration-0021: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
