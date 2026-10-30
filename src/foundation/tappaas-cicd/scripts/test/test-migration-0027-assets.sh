#!/usr/bin/env bash
# test-migration-0027-assets.sh — the fixture test for migration 0027 (#906, ADR-040).
#
# hrossen's positions.json as 0020 wrote it (the ISP modem loose in basement,
# patchpanel1, eight placements, the ISP hand-off) with a printer recorded from
# a switch port (its MAC, its cable), its three pvehost instances and its
# switch configuration (three switches, one AP). Before → after against
# fixtures/0027-hrossen/positions-after.json, --check writes nothing, applying
# twice is a no-op, the backup holds positions.json, a site with no
# positions.json gets one, an asset already playing a role is not made again,
# and each refusal leaves every file as it was. Test 9z sweeps this directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0027-devices-become-assets.sh"
FIX="${HERE}/fixtures/0027-hrossen"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
yes() { if eval "$2"; then echo yes; else echo no; fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }
[[ -f "${FIX}/positions.json" && -f "${FIX}/positions-after.json" ]] || { echo "  ✗ the fixtures are not in ${FIX}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0027.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"
BK="${CFG}/.migrations/backup/0027"

fresh() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    cp "${FIX}/positions.json" "${CFG}/positions.json"
    cp "${HERE}/fixtures/0022-hrossen/"tappaas*.json "${CFG}/"
    cp "${HERE}/fixtures/0021-hrossen/switch-configuration-desired.json" "${CFG}/"
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${BK}" bash "${M}" "$@" 2>&1; }
pos() { jq -c "$1" "${CFG}/positions.json"; }
snap() { (cd "${CFG}" && for f in *.json; do printf '%s %s\n' "${f}" "$(cksum < "${f}")"; done); }

fresh
before="$(jq -c . "${CFG}/positions.json")"
out="$(run --check)"; rc=$?
ck "--check: exit 0"                                   0 "${rc}"
ck "…writes nothing"                                   "${before}" "$(jq -c . "${CFG}/positions.json")"
ck "…makes no backup"                                  no "$(yes '' '[[ -e "${BK}" ]]')"
ck "…and says what it would do"                        yes "$(yes '' '[[ "${out}" == *"would: devices{} → assets{}: 3 device(s) (ISP modem, patchpanel1, printer)"* && "${out}" == *"would: asset srv-01 tappaas1 (server)"* && "${out}" == *"would: asset ap-01 Nano HD (access-point)"* ]]')"

out="$(run)"; rc=$?
ck "the run succeeds"                                  0 "${rc}"
ck "before → after: the expected document"             "$(jq -c . "${FIX}/positions-after.json")" "$(pos .)"
ck "devices{} is gone, assets{} is there"              '[false,10]' "$(pos '[has("devices"), (.assets | length)]')"
ck "a device keeps its name, kind and model, playing itself" '{"kind":"modem","model":"generic/isp-modem","stage":"placed","role":"ISP modem"}' "$(pos '.assets["ISP modem"]')"
ck "…its ports rj45 at 1g"                             '["rj45:1g"]' "$(pos '[.assets.patchpanel1.ports[] | "\(.kind):\(.speed)"] | unique')"
ck "…its MAC on its cabled port, lower case"           '"eth0 aa:bb:cc:00:11:22"' "$(pos '.assets.printer.ports[0] | "\(.name) \(.mac)"')"
ck "…placed when placed, else in stock"                '["placed","stock","stock"]' "$(pos '[.assets["ISP modem"].stage, .assets.patchpanel1.stage, .assets.printer.stage]')"
ck "a tag per node, in node order (the primary first)" '["srv-01 tappaas1","srv-02 tappaas2","srv-03 tappaas3"]' "$(pos '[.assets | to_entries[] | select(.value.kind == "server") | "\(.key) \(.value.role)"]')"
ck "…its displayName the role's name, no serial"        '["tappaas1",false]' "$(pos '[.assets["srv-01"].displayName, (.assets["srv-01"] | has("serial"))]')"
ck "a tag per switch, in the configuration's order"    '["sw-01 USW Pro XG 10 PoE","sw-02 crs-a","sw-03 crs-b"]' "$(pos '[.assets | to_entries[] | select(.value.kind == "switch") | "\(.key) \(.value.role)"]')"
ck "…with its vendor and model"                        '"unifi USWED77"' "$(pos '.assets["sw-01"] | "\(.vendor) \(.model)"')"
ck "an AP: ap-01, placed where its role is"            '"Nano HD placed"' "$(pos '.assets["ap-01"] | "\(.role) \(.stage)"')"
ck "placements and cables untouched"                   "$(jq -c '[.placements, .cables]' <<<"${before}")" "$(pos '[.placements, .cables]')"
ck "the keys in the schema's order"                    '["version","rooms","racks","placements","assets","cables"]' "$(pos 'keys_unsorted')"
ck "the backup holds positions.json"                   "${before}" "$(jq -c . "${BK}/positions.json")"
ck "the node records are untouched"                    "$(jq -c . "${HERE}/fixtures/0022-hrossen/tappaas1.json")" "$(jq -c . "${CFG}/tappaas1.json")"
ck "no temp file left"                                 no "$(yes '' 'compgen -G "${CFG}/*.tmp" >/dev/null')"

after="$(snap)"
out="$(run)"; rc=$?
ck "twice: exit 0"                                     0 "${rc}"
ck "…changes nothing"                                  "${after}" "$(snap)"
ck "…and says so"                                      yes "$(yes '' '[[ "${out}" == *"nothing to migrate"* ]]')"

# A node added later gets the next tag on a deliberate rerun; an archived one none.
jq '.status = "archived"' "${CFG}/tappaas3.json" > "${TMP}/t" && cp "${TMP}/t" "${CFG}/tappaas9.json"
cp "${CFG}/tappaas1.json" "${CFG}/tappaas10.json"
run >/dev/null; ck "a new node: the next tag, srv-04"   '["tappaas10",false]' "$(pos '[.assets["srv-04"].role, (.assets | has("srv-05"))]')"

# An asset the operator added for a role first: none is made for it.
fresh; jq '.devices = {} | .assets = {} | del(.devices)' "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"
jq '.assets = {"box-a": {kind: "server", stage: "placed", serial: "CZC1", role: "tappaas1"}}' "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"
run >/dev/null
ck "an asset already playing tappaas1: none made for it" '["box-a","srv-01 tappaas2"]' "$(pos '[(.assets | to_entries[] | select(.value.role == "tappaas1") | .key), (.assets | to_entries[] | select(.key == "srv-01") | "\(.key) \(.value.role)")]')"

# No positions.json: one is made for the nodes, switches and APs.
fresh; rm -f "${CFG}/positions.json"
out="$(run)"; rc=$?
ck "no positions.json: exit 0, one made"               "0 yes" "${rc} $(yes '' '[[ -f "${CFG}/positions.json" ]]')"
ck "…with an asset each, in stock"                     '[7,["stock"]]' "$(pos '[(.assets | length), ([.assets[].stage] | unique)]')"
ck "…and the backup says there was none"               yes "$(yes '' '[[ -f "${BK}/positions.json.absent" ]]')"

# Nothing at all: nothing to do.
rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "an empty config: exit 0, nothing to do"            "0 yes no" "${rc} $(yes '' '[[ "${out}" == *"nothing to migrate"* ]]') $(yes '' '[[ -e "${CFG}/positions.json" ]]')"

refuse() {  # <what> <setup command>
    fresh; eval "$2"
    local s; s="$(snap)"
    out="$(run)"; rc=$?
    ck "refused: $1 (exit 1)"                          1 "${rc}"
    ck "…nothing changed"                              "${s}" "$(snap)"
    ck "…no backup"                                    no "$(yes '' '[[ -e "${BK}" ]]')"
}
refuse "positions.json not JSON" 'echo "{" > "${CFG}/positions.json"'
refuse "positions.json not an object" 'echo "[]" > "${CFG}/positions.json"'
refuse "devices not an object" 'jq ".devices = []" "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"'
refuse "devices{} and assets{} both" 'jq ".assets = {}" "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"'
refuse "a device of an unknown kind" 'jq ".devices.printer.kind = \"printer\"" "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"'
refuse "a device named as a node" 'jq ".devices.tappaas2 = {kind: \"other\", ports: [\"1\"]}" "${CFG}/positions.json" > "${TMP}/p" && mv "${TMP}/p" "${CFG}/positions.json"'
refuse "a switch configuration not an object" 'echo "[]" > "${CFG}/switch-configuration-desired.json"'

echo ""
echo "migration 0027: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
