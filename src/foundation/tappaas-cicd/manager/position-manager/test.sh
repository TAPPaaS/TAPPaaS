#!/usr/bin/env bash
# test.sh — position-manager offline test suite.
#
# Compiles the TS sources + unit tests, runs the unit suite (the verbs, the
# document check and the topology's rack view over hrossen's topology, the
# help manifest, the catalog), then drives the compiled CLI against a temp
# config dir with hrossen's topology handed in (--topology) and a fixture
# catalog — never the live config, the topology verb or a device. position-manager
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
else bad "unit tests do not compile"; echo "position-manager test: ${pass} passed, ${fail} failed"; exit 1; fi
for unit in $(cd "${HERE}/test/unit" && ls *.test.ts | sed 's/\.test\.ts$//'); do
    run_ts "RM_FIXTURE_DIR='${HERE}/test/fixtures' RM_CATALOG_DIR='${HERE}/faceplates' node '${DIST}/manager/position-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1 \
        && ok "unit: ${unit}" || bad "unit: ${unit} (rerun: RM_FIXTURE_DIR=${HERE}/test/fixtures RM_CATALOG_DIR=${HERE}/faceplates node ${DIST}/manager/position-manager/test/unit/${unit}.test.js)"
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
    run_ts "node '${DIST}/manager/position-manager/src/main.js' $(printf "'%s' " "$@")"; }
DOC="${FIX}/cfg/positions.json"

RM rack add rack1 --units 42 --check >/dev/null 2>&1
[[ ! -f "${DOC}" ]] && ok "rack add --check writes nothing" || bad "rack add --check wrote positions.json"
_o="$(RM rack add rack1 --units 42 --check 2>&1 | grep -v Warning)"  # the fixture catalog's broken plate warns
[[ "${_o}" == "[check] would add rack 'rack1' (42U, 19in, numbered bottom-up)" ]] && ok "rack add --check: one line, what it would add" || bad "rack add --check said: ${_o}"
_o="$(RM rack add rack1 --units 42 --check --json 2>/dev/null)"
[[ "$(jq -r '.racks.rack1.units' <<<"${_o}" 2>/dev/null)" == "42" ]] && ok "--check --json: the whole resulting document" || bad "--check --json: ${_o:0:200}"
RM rack add rack1 --units 42 >/dev/null 2>&1 && ok "rack add" || bad "rack add"
[[ "$(jq -r '.racks.rack1.numbering' "${DOC}")" == "bottom-up" ]] && ok "rack add: numbered from the bottom" || bad "rack add: numbering"
RM rack add rack1 >/dev/null 2>&1 && bad "rack add: a duplicate refused" || ok "rack add: a duplicate refused"
_o="$(RM rack add rack1 --check 2>&1)"; _rc=$?; _o="$(grep -v Warning <<<"${_o}")"
[[ "${_rc}" == 1 && "${_o}" == "[refused] rack rack1 already exists" ]] && ok "a refused --check: one [refused] line, exit 1" || bad "refused --check (rc ${_rc}): ${_o}"
RM place tappaas1 --rack rack1 --u 10 --faceplate generic/server-2u --description "placeholder position, set by the operator" --topology "${TOPO}" >/dev/null 2>&1 \
    && ok "place: a node" || bad "place: a node"
[[ "$(jq -r '.placements.tappaas1.height' "${DOC}")" == "2" ]] && ok "place: its faceplate's height" || bad "place: height"
RM place tappaas2 --rack rack1 --u 11 --faceplate generic/server-2u --topology "${TOPO}" >/dev/null 2>&1 && bad "place: an overlap refused" || ok "place: an overlap refused"
RM place tappaas9 --rack rack1 --u 20 --topology "${TOPO}" >/dev/null 2>&1 && bad "place: a device the topology lacks refused" || ok "place: a device the topology lacks refused"
RM place "${USW}" --rack rack1 --u 20 --faceplate unifi/usw-pro-xg-10-poe --topology "${TOPO}" >/dev/null 2>&1 && ok "place: a name with spaces" || bad "place: the switch"
RM place modify tappaas1 --set u=14 --topology "${TOPO}" >/dev/null 2>&1 && ok "place modify: a move" || bad "place modify: a move"
[[ "$(jq -r '.placements.tappaas1.u' "${DOC}")" == "14" ]] && ok "place modify: recorded" || bad "place modify: recorded"
RM place modify tappaas1 --unset description --topology "${TOPO}" >/dev/null 2>&1 && [[ "$(jq -r '.placements.tappaas1.description // "gone"' "${DOC}")" == "gone" ]] \
    && ok "place modify --unset: a text cleared" || bad "place modify --unset"
RM place modify tappaas1 --set description="placeholder position, set by the operator" --topology "${TOPO}" >/dev/null 2>&1 || bad "place modify: the description back"
RM cable add --from "${USW}:5" --to "ISP modem:LAN 1" --to-faceplate generic/isp-modem --kind uplink --label "ISP hand-off" --topology "${TOPO}" >/dev/null 2>&1 \
    && ok "cable add: the ISP hand-off" || bad "cable add: the ISP hand-off"
RM cable add --from "${USW}:13" --to "tappaas1:nic2" --topology "${TOPO}" >/dev/null 2>&1 && bad "cable add: a port the switch lacks refused" || ok "cable add: a port the switch lacks refused"
[[ "$(RM cable list --json 2>/dev/null | jq -r '.[0].to.faceplate')" == "generic/isp-modem" ]] && ok "cable list --json" || bad "cable list --json"
RM validate --topology "${TOPO}" 2>&1 | grep -c "ISP modem is neither seen by the topology nor recorded" >/dev/null && ok "validate: a device only a cable names is pointed out" || bad "validate: the cable-only modem"
CABLE_BEFORE="$(jq -c '.cables' "${DOC}")"
RM device add "ISP modem" --kind modem --model generic/isp-modem --topology "${TOPO}" >/dev/null 2>&1 && ok "device add: the ISP modem recorded" || bad "device add"
[[ "$(jq -c '.cables' "${DOC}")" == "${CABLE_BEFORE}" ]] && ok "device add: its cable unchanged" || bad "device add changed the cable"
RM validate --topology "${TOPO}" 2>&1 | grep -c "neither seen" >/dev/null && bad "validate: still warns after the record" || ok "validate: the recorded modem is a device"
[[ "$(RM device list --json 2>/dev/null | jq -r '.[0].ports | join(",")')" == "WAN,LAN 1" ]] && ok "device list --json: its ports from its model" || bad "device list"
RM device add tappaas1 --kind other --ports 1 --topology "${TOPO}" >/dev/null 2>&1 && bad "device add: a seen device refused" || ok "device add: a seen device refused"
RM room add basement --display-name Basement >/dev/null 2>&1 && ok "room add" || bad "room add"
printf '{"locations":{"home":{"country":"DK","timezone":"Europe/Copenhagen"},"far":{"country":"DE"}},"primaryLocation":"home"}' > "${FIX}/cfg/site.json"
RM room add shed --location nowhere >/dev/null 2>&1 && bad "room add: a location the site lacks refused" || ok "room add: a location the site lacks refused"
RM room add shed --location far >/dev/null 2>&1 && [[ "$(jq -r '.rooms.shed.location' "${DOC}")" == "far" ]] && ok "room add --location" || bad "room add --location"
[[ "$(RM room show shed --json 2>/dev/null | jq -r '.location')" == "far" ]] && ok "room show --json: its location" || bad "room show: location"
RM room delete shed >/dev/null 2>&1 || bad "room delete shed"
RM room add attic --building House >/dev/null 2>&1 && bad "room add: --building refused (the site has it)" || ok "room add: --building refused (the site has it)"
RM place "ISP modem" --room basement --topology "${TOPO}" >/dev/null 2>&1 && ok "place --room: the modem loose in the basement" || bad "place --room"
[[ "$(jq -r '.placements["ISP modem"] | "\(.room) \(.rack // "-") \(.u // "-")"' "${DOC}")" == "basement - -" ]] && ok "place --room: no rack, no unit" || bad "place --room: recorded"
[[ "$(RM room list --json 2>/dev/null | jq -r '.[0].loose | join(",")')" == "ISP modem" ]] && ok "room list --json: what stands loose in it" || bad "room list"
RM room delete basement >/dev/null 2>&1 && bad "room delete: refused while it holds a device" || ok "room delete: refused while it holds a device"
RM validate --topology "${TOPO}" >/dev/null 2>&1 && ok "validate: the result is valid" || bad "validate"
[[ "$(RM validate --topology "${TOPO}" --json 2>/dev/null | jq -r '.valid')" == "true" ]] && ok "validate --json" || bad "validate --json"
[[ "$(RM rack show rack1 --json 2>/dev/null | jq -r '.placements | length')" == "2" ]] && ok "rack show --json: what is placed in it" || bad "rack show --json"
[[ "$(RM place list --json 2>/dev/null | jq -r '.[0].device')" == "${USW}" ]] && ok "place list: highest first" || bad "place list"
RM rack show rack1 >/dev/null 2>&1 && ok "rack show" || bad "rack show"
[[ "$(RM export --json 2>/dev/null | jq -r '[.catalog[].key] | join(",")')" == "generic/isp-modem,generic/server-2u,unifi/usw-pro-xg-10-poe" ]] && ok "export: the document and the catalog" || bad "export"
[[ "$(RM export --json 2>/dev/null | jq -r '.catalogErrors | length')" == "1" ]] && ok "export: a broken catalog entry is reported, not loaded" || bad "export: catalog errors"
RM faceplates show unifi/usw-pro-xg-10-poe 2>/dev/null | grep -c '\[11 Port 11·sfp+\]' >/dev/null && ok "faceplates show: one line per port row" || bad "faceplates show"
[[ "$(RM faceplates show generic/server-2u --device tappaas1 --topology "${TOPO}" --json 2>/dev/null | jq -r '[.rows[0][].id] | join(",")')" == "nic2,nic3,nic4" ]] \
    && ok "faceplates show --device: a generic plate filled from the node" || bad "faceplates show --device"
RM rack delete rack1 >/dev/null 2>&1 && bad "rack delete: refused while it holds mounts" || ok "rack delete: refused while it holds mounts"
RM device add patch1 --kind patch-panel --ports 24 --topology "${TOPO}" >/dev/null 2>&1 && RM place patch1 --rack rack1 --u 30 --topology "${TOPO}" >/dev/null 2>&1 && ok "a patch panel recorded and placed" || bad "patch panel"
RM cable split "${USW}:2" --via patch1:1 --topology "${TOPO}" --check >/dev/null 2>&1 && [[ "$(jq '[.cables[] | select(.origin)] | length' "${DOC}")" == "0" ]] && ok "cable split --check: a preview, nothing written" || bad "cable split --check"
RM cable split "${USW}:2" --via patch1:1 --topology "${TOPO}" >/dev/null 2>&1 && ok "cable split: the seen link through the panel" || bad "cable split"
[[ "$(jq -r '[.cables[] | select(.origin == "seen") | "\(.from.device):\(.from.port)>\(.to.device):\(.to.port):\(.to.side // .from.side)"] | join(" ")' "${DOC}")" == "${USW}:2>patch1:1:front patch1:1>tappaas2:enp97s0:rear" ]] \
    && ok "cable split: two segments, front and rear" || bad "cable split: segments"
RM cable split "${USW}:3" --via patch1:1 --topology "${TOPO}" >/dev/null 2>&1 && bad "cable split: a busy panel port refused" || ok "cable split: a busy panel port refused"
RM cable join patch1:1 >/dev/null 2>&1 && [[ "$(jq '[.cables[] | select(.origin)] | length' "${DOC}")" == "0" ]] && ok "cable join: the link is the topology's again" || bad "cable join"
RM unplace patch1 >/dev/null 2>&1 && RM device remove patch1 >/dev/null 2>&1 || bad "patch panel removed"
RM cable remove "ISP modem:LAN 1" >/dev/null 2>&1 && ok "cable remove" || bad "cable remove"
RM device remove "ISP modem" >/dev/null 2>&1 && bad "device remove: refused while placed" || ok "device remove: refused while placed"
RM unplace "ISP modem" >/dev/null 2>&1 || bad "unplace: the loose modem"
RM device remove "ISP modem" >/dev/null 2>&1 && ok "device remove: once no cable names it" || bad "device remove"
RM room delete basement >/dev/null 2>&1 && ok "room delete: once empty" || bad "room delete"
RM unplace tappaas1 >/dev/null 2>&1 && RM unplace "${USW}" >/dev/null 2>&1 && ok "unplace" || bad "unplace"
RM rack delete rack1 >/dev/null 2>&1 && ok "rack delete: once empty" || bad "rack delete"
[[ "$(jq -r '.racks | length' "${DOC}")" == "0" ]] && ok "rack delete: recorded" || bad "rack delete: recorded"
[[ -z "$(ls -A "${FIX}/cfg" | grep -v '^positions.json$' | grep -v '^site.json$')" ]] && ok "no lock or temp file left behind" || bad "left behind: $(ls -A "${FIX}/cfg")"
# The catalog as shipped, through the CLI.
RMC() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" TAPPAAS_FACEPLATES="${HERE}/faceplates" \
    run_ts "node '${DIST}/manager/position-manager/src/main.js' $(printf "'%s' " "$@")"; }
[[ "$(RMC faceplates list --json 2>/dev/null | jq 'length')" -ge 11 ]] && ok "faceplates list: the shipped catalog" || bad "faceplates list"
[[ "$(RMC faceplates show mikrotik/crs317-1g-16s 2>/dev/null | grep -c '\[sfp-sfpplus')" == "1" ]] && ok "faceplates show: the CRS317's one row of cages" || bad "faceplates show mikrotik/crs317-1g-16s"
[[ "$(RMC faceplates show unifi/usw-pro-xg-10-poe --device "${USW}" --topology "${TOPO}" --json 2>/dev/null | jq -r '[.rows[][] | select(. != null and .id == "5")][0].zones[0]')" == "wan" ]] \
    && ok "faceplates show --device: port 5 carries the wan zone" || bad "faceplates show --device on the UniFi plate"
# The site's own faceplates: added, listed as the site's, placed, changed, deleted.
RMC faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --display-name "NAS 4" --check >/dev/null 2>&1 && [[ "$(jq -r '.faceplates // "none"' "${DOC}")" == "none" ]] \
    && ok "faceplate add --check: nothing written" || bad "faceplate add --check"
RMC faceplate add acme/nas-4 --units 2 --ports "4xrj45, 2xsfp+" --kind server --display-name "NAS 4" --match NAS-4X >/dev/null 2>&1 \
    && [[ "$(jq -r '.faceplates["acme/nas-4"] | "\(.units) \(.ports) \(.match[0])"' "${DOC}")" == "2 4xrj45, 2xsfp+ NAS-4X" ]] && ok "faceplate add: in positions.json" || bad "faceplate add"
RMC faceplate add acme/bad --units 1 --ports "4xwhat" >/dev/null 2>&1 && bad "faceplate add: a broken spec refused" || ok "faceplate add: a broken spec refused"
[[ "$(RMC faceplates list --json 2>/dev/null | jq -r '.[0] | "\(.key) \(.site) \(.ports) \(.spec)"')" == "acme/nas-4 true 6 4xrj45, 2xsfp+" ]] && ok "faceplates list --json: the site's first, marked site" || bad "faceplates list: the site's plate"
RMC faceplates list 2>/dev/null | grep 'acme/nas-4' | grep -q site && ok "faceplates list: marked site" || bad "faceplates list: the mark"
[[ "$(RMC faceplates show acme/nas-4 --file 2>/dev/null | jq -r '"\(.vendor) \(.model) \(.ports)"')" == "acme NAS 4 4xrj45, 2xsfp+" ]] && ok "faceplates show --file: the plate as a catalog file" || bad "faceplates show --file"
[[ "$(RMC export --json 2>/dev/null | jq -r '[.catalog[] | select(.site) | .key] | join(",")')" == "acme/nas-4" ]] && ok "export: the site's plate in the catalog" || bad "export: the site's plate"
RMC faceplate add generic/patch-panel-24 --units 1 --ports "24xrj45[2-98]" --kind patch-panel --passive >/dev/null 2>&1 && ok "faceplate add: a shipped key" || bad "faceplate add: a shipped key"
RMC validate 2>&1 | grep -q "overrides the shipped one" && ok "validate: the override pointed out" || bad "validate: the override"
RMC faceplate delete generic/patch-panel-24 >/dev/null 2>&1 && ok "faceplate delete: the override goes" || bad "faceplate delete: the override"
RMC faceplate modify acme/nas-4 --set "ports=4xrj45/4xrj45" --set description="the backup NAS" >/dev/null 2>&1 \
    && [[ "$(jq -r '.faceplates["acme/nas-4"] | "\(.ports) \(.description)"' "${DOC}")" == "4xrj45/4xrj45 the backup NAS" ]] && ok "faceplate modify" || bad "faceplate modify"
RMC faceplate delete acme/nas-4 >/dev/null 2>&1 && [[ "$(jq -r '.faceplates // "none"' "${DOC}")" == "none" ]] && ok "faceplate delete" || bad "faceplate delete"
# The old verbs answer for one release.
RM rack add rack1 --units 42 >/dev/null 2>&1 || bad "rack add (for the old verbs)"
RM mount add tappaas3 --rack rack1 --u 2 --faceplate generic/server-2u --topology "${TOPO}" --check >/dev/null 2>&1 && ok "mount add: the old verb answers (place)" || bad "mount add alias"
RM mount add tappaas3 --rack rack1 --u 2 --faceplate generic/server-2u --topology "${TOPO}" >/dev/null 2>&1 && RM mount modify tappaas3 --set u=4 --topology "${TOPO}" >/dev/null 2>&1 \
    && [[ "$(RM mount show tappaas3 --json 2>/dev/null | jq -r '.u')" == "4" ]] && RM mount remove tappaas3 >/dev/null 2>&1 && [[ "$(jq -r '.placements.tappaas3 // "gone"' "${DOC}")" == "gone" ]] \
    && ok "mount modify, mount show, mount remove: the old verbs answer" || bad "mount aliases"
RM rack delete rack1 >/dev/null 2>&1 || bad "rack delete (after the old verbs)"
[[ "$(RM --help --json 2>/dev/null | jq -r '[.verbs[] | select(.verb == "place") | .keys[] | join(" ")] | join(",")')" == "place,mount add" ]] && ok "--help --json: place, with mount add as its alias" || bad "--help --json: place's alias"
# device record: a device a switch port sees becomes a recorded one, its cable kept.
SEEN="${FIX}/topology-seen.json"
jq --arg sw "${USW}" '.devices += [{name: "aa:bb:cc:00:11:22", kind: "device", vendor: null, model: null, source: "seen", location: null,
    seen: {switch: $sw, port: "8", mac: "aa:bb:cc:00:11:22", lldp: {name: "printer-1", port: "eth0"}, lease: null}}]' "${TOPO}" > "${SEEN}"
RM device record "${USW}:8" --name printer --kind other --topology "${SEEN}" --check >/dev/null 2>&1 && [[ "$(jq -r '.devices.printer // "none"' "${DOC}")" == "none" ]] && ok "device record --check: nothing written" || bad "device record --check"
RM device record "${USW}:9" --name printer --kind other --topology "${SEEN}" >/dev/null 2>&1 && bad "device record: a port that sees nothing refused" || ok "device record: a port that sees nothing refused"
RM device record aa:bb:cc:00:11:22 --name printer --kind other --topology "${SEEN}" >/dev/null 2>&1 && ok "device record <mac>" || bad "device record <mac>"
[[ "$(jq -r '.devices.printer | "\(.mac) \(.ports | join(",")) \(.displayName)"' "${DOC}")" == "aa:bb:cc:00:11:22 eth0 printer-1" ]] && ok "device record: its MAC, its LLDP port and name kept" || bad "device record: the record"
[[ "$(jq -r --arg sw "${USW}" '[.cables[] | select(.from.device == $sw and .from.port == "8") | .to | "\(.device):\(.port)"] | join(",")' "${DOC}")" == "printer:eth0" ]] && ok "device record: the port's cable recorded" || bad "device record: the cable"
RM device record "${USW}:8" --name printer2 --kind other --topology "${SEEN}" >/dev/null 2>&1 && bad "device record: a port with a recorded cable refused" || ok "device record: a port with a recorded cable refused"
RM cable remove "${USW}:8" >/dev/null 2>&1 && RM device remove printer >/dev/null 2>&1 || bad "device record: undone"
# A site the migration has not reached: racks.json is read, never written.
LEG="$(mktemp -d "${TMPDIR:-/tmp}/rm-leg.XXXXXX")"
printf '{"version":1,"racks":{"r1":{"units":10,"width":"19in","numbering":"bottom-up"}}}' > "${LEG}/racks.json"
RML() { CONFIG_DIR="${LEG}" TAPPAAS_CONFIG="${LEG}" TAPPAAS_FACEPLATES="${HERE}/test/fixtures/faceplates" \
    run_ts "node '${DIST}/manager/position-manager/src/main.js' $(printf "'%s' " "$@")"; }
[[ "$(RML rack list --json 2>/dev/null | jq -r '.[0].name')" == "r1" ]] && ok "racks.json read while the migration has not run" || bad "racks.json not read"
RML rack add r2 >/dev/null 2>&1 && bad "a write beside racks.json refused" || ok "a write beside racks.json refused"
[[ ! -e "${LEG}/positions.json" ]] && ok "nothing written beside racks.json" || bad "positions.json written beside racks.json"
rm -rf -- "${LEG}"
RM --help --json 2>/dev/null | jq -e '.verbs | length > 10' >/dev/null && ok "--help --json is the verb manifest" || bad "--help --json"

rm -rf -- "${DIST}"
echo ""
echo "position-manager test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
