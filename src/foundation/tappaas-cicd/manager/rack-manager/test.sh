#!/usr/bin/env bash
# test.sh — rack-manager offline test suite.
#
# Compiles the TS sources + unit tests, runs the unit suite (the verbs, the
# document check and the topology's rack view over hrossen's topology, the
# help manifest, the catalog), then drives the compiled CLI against a temp
# config dir with hrossen's topology handed in (--topology) and a fixture
# catalog — never the live config, the topology verb or a device. rack-manager
# changes no device, so there is no deep tier.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

for f in "${HERE}"/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done

run_ts() {
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then nix-shell -p typescript nodejs_22 --run "$1"
    else return 127; fi
}
DIST="${HERE}/dist-test"
rm -rf -- "${DIST}"
run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1 && ok "tsc --noEmit clean (src)" || bad "tsc --noEmit reported type errors (src)"
if run_ts "tsc -p '${HERE}/test/unit/tsconfig.json'" >/dev/null 2>&1; then ok "sources + unit tests compile"
else bad "unit tests do not compile"; echo "rack-manager test: ${pass} passed, ${fail} failed"; exit 1; fi
for unit in $(cd "${HERE}/test/unit" && ls *.test.ts | sed 's/\.test\.ts$//'); do
    run_ts "RM_FIXTURE_DIR='${HERE}/test/fixtures' RM_CATALOG_DIR='${HERE}/faceplates' node '${DIST}/manager/rack-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1 \
        && ok "unit: ${unit}" || bad "unit: ${unit} (rerun: RM_FIXTURE_DIR=${HERE}/test/fixtures RM_CATALOG_DIR=${HERE}/faceplates node ${DIST}/manager/rack-manager/test/unit/${unit}.test.js)"
done

# ── the CLI against a fixture config ─────────────────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/rm-fix.XXXXXX")"
trap 'rm -rf "${FIX}" "${DIST}"' EXIT
mkdir -p "${FIX}/cfg"
TOPO="${HERE}/test/fixtures/topology-hrossen.json"
USW="USW Pro XG 10 PoE"
# Both config spellings: TS reads TAPPAAS_CONFIG first, and an inherited one
# would point this suite at the live config. The catalog is the fixture's.
RM() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" TAPPAAS_FACEPLATES="${HERE}/test/fixtures/faceplates" \
    run_ts "node '${DIST}/manager/rack-manager/src/main.js' $(printf "'%s' " "$@")"; }
DOC="${FIX}/cfg/racks.json"

RM rack add rack1 --units 42 --building House --check >/dev/null 2>&1
[[ ! -f "${DOC}" ]] && ok "rack add --check writes nothing" || bad "rack add --check wrote racks.json"
RM rack add rack1 --units 42 --building House >/dev/null 2>&1 && ok "rack add" || bad "rack add"
[[ "$(jq -r '.racks.rack1.numbering' "${DOC}")" == "bottom-up" ]] && ok "rack add: numbered from the bottom" || bad "rack add: numbering"
RM rack add rack1 >/dev/null 2>&1 && bad "rack add: a duplicate refused" || ok "rack add: a duplicate refused"
RM mount add tappaas1 --rack rack1 --u 10 --faceplate generic/server-2u --description "placeholder position, set by the operator" --topology "${TOPO}" >/dev/null 2>&1 \
    && ok "mount add: a node" || bad "mount add: a node"
[[ "$(jq -r '.mounts.tappaas1.height' "${DOC}")" == "2" ]] && ok "mount add: its faceplate's height" || bad "mount add: height"
RM mount add tappaas2 --rack rack1 --u 11 --faceplate generic/server-2u --topology "${TOPO}" >/dev/null 2>&1 && bad "mount add: an overlap refused" || ok "mount add: an overlap refused"
RM mount add tappaas9 --rack rack1 --u 20 --topology "${TOPO}" >/dev/null 2>&1 && bad "mount add: a device the topology lacks refused" || ok "mount add: a device the topology lacks refused"
RM mount add "${USW}" --rack rack1 --u 20 --faceplate unifi/usw-pro-xg-10-poe --topology "${TOPO}" >/dev/null 2>&1 && ok "mount add: a name with spaces" || bad "mount add: the switch"
RM mount modify tappaas1 --set u=14 --topology "${TOPO}" >/dev/null 2>&1 && ok "mount modify: a move" || bad "mount modify: a move"
[[ "$(jq -r '.mounts.tappaas1.u' "${DOC}")" == "14" ]] && ok "mount modify: recorded" || bad "mount modify: recorded"
RM cable add --from "${USW}:5" --to "ISP modem:LAN 1" --to-faceplate generic/isp-modem --kind uplink --label "ISP hand-off" --topology "${TOPO}" >/dev/null 2>&1 \
    && ok "cable add: the ISP hand-off" || bad "cable add: the ISP hand-off"
RM cable add --from "${USW}:13" --to "tappaas1:nic2" --topology "${TOPO}" >/dev/null 2>&1 && bad "cable add: a port the switch lacks refused" || ok "cable add: a port the switch lacks refused"
[[ "$(RM cable list --json 2>/dev/null | jq -r '.[0].to.faceplate')" == "generic/isp-modem" ]] && ok "cable list --json" || bad "cable list --json"
RM validate --topology "${TOPO}" >/dev/null 2>&1 && ok "validate: the result is valid" || bad "validate"
[[ "$(RM validate --topology "${TOPO}" --json 2>/dev/null | jq -r '.valid')" == "true" ]] && ok "validate --json" || bad "validate --json"
[[ "$(RM rack show rack1 --json 2>/dev/null | jq -r '.mounts | length')" == "2" ]] && ok "rack show --json: its mounts" || bad "rack show --json"
[[ "$(RM mount list --json 2>/dev/null | jq -r '.[0].device')" == "${USW}" ]] && ok "mount list: highest first" || bad "mount list"
RM rack show rack1 >/dev/null 2>&1 && ok "rack show" || bad "rack show"
[[ "$(RM export --json 2>/dev/null | jq -r '[.catalog[].key] | join(",")')" == "generic/isp-modem,generic/server-2u,unifi/usw-pro-xg-10-poe" ]] && ok "export: the document and the catalog" || bad "export"
[[ "$(RM export --json 2>/dev/null | jq -r '.catalogErrors | length')" == "1" ]] && ok "export: a broken catalog entry is reported, not loaded" || bad "export: catalog errors"
RM faceplates show unifi/usw-pro-xg-10-poe 2>/dev/null | grep -q '\[11 Port 11·sfp+\]' && ok "faceplates show: one line per port row" || bad "faceplates show"
[[ "$(RM faceplates show generic/server-2u --device tappaas1 --topology "${TOPO}" --json 2>/dev/null | jq -r '[.rows[0][].id] | join(",")')" == "nic2,nic3,nic4" ]] \
    && ok "faceplates show --device: a generic plate filled from the node" || bad "faceplates show --device"
RM rack delete rack1 >/dev/null 2>&1 && bad "rack delete: refused while it holds mounts" || ok "rack delete: refused while it holds mounts"
RM cable remove "ISP modem:LAN 1" >/dev/null 2>&1 && ok "cable remove" || bad "cable remove"
RM mount remove tappaas1 >/dev/null 2>&1 && RM mount remove "${USW}" >/dev/null 2>&1 && ok "mount remove" || bad "mount remove"
RM rack delete rack1 >/dev/null 2>&1 && ok "rack delete: once empty" || bad "rack delete"
[[ "$(jq -r '.racks | length' "${DOC}")" == "0" ]] && ok "rack delete: recorded" || bad "rack delete: recorded"
[[ -z "$(ls -A "${FIX}/cfg" | grep -v '^racks.json$')" ]] && ok "no lock or temp file left behind" || bad "left behind: $(ls -A "${FIX}/cfg")"
# The catalog as shipped, through the CLI.
RMC() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" TAPPAAS_FACEPLATES="${HERE}/faceplates" \
    run_ts "node '${DIST}/manager/rack-manager/src/main.js' $(printf "'%s' " "$@")"; }
[[ "$(RMC faceplates list --json 2>/dev/null | jq 'length')" -ge 11 ]] && ok "faceplates list: the shipped catalog" || bad "faceplates list"
[[ "$(RMC faceplates show mikrotik/crs317-1g-16s 2>/dev/null | grep -c 'sfp-sfpplus')" == "2" ]] && ok "faceplates show: the CRS317's two SFP+ rows" || bad "faceplates show mikrotik/crs317-1g-16s"
[[ "$(RMC faceplates show unifi/usw-pro-xg-10-poe --device "${USW}" --topology "${TOPO}" --json 2>/dev/null | jq -r '.rows[0][2].zones[0]')" == "wan" ]] \
    && ok "faceplates show --device: port 5 carries the wan zone" || bad "faceplates show --device on the UniFi plate"
RM --help --json 2>/dev/null | jq -e '.verbs | length > 10' >/dev/null && ok "--help --json is the verb manifest" || bad "--help --json"

rm -rf -- "${DIST}"
echo ""
echo "rack-manager test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
