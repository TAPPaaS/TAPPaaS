#!/usr/bin/env bash
# test.sh — asset-manager offline test suite.
#
# Compiles the TS sources + unit tests, runs the unit suite (the verbs, the
# document check and the topology's rack view over hrossen's topology, the
# help manifest, the catalog), then drives the compiled CLI against a temp
# config dir with hrossen's topology handed in (--topology) and a fixture
# catalog — never the live config, the topology verb or a device. asset-manager
# changes no device, so there is no deep tier. The CMDB client is pointed at
# a socket nobody serves, so every report is spooled under the temp config
# (never the live cmdb-controller): what the verbs report is read from there.
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
else bad "unit tests do not compile"; echo "asset-manager test: ${pass} passed, ${fail} failed"; exit 1; fi
for unit in $(cd "${HERE}/test/unit" && ls *.test.ts | sed 's/\.test\.ts$//'); do
    run_ts "RM_FIXTURE_DIR='${HERE}/test/fixtures' RM_CATALOG_DIR='${HERE}/faceplates' node '${DIST}/manager/asset-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1 \
        && ok "unit: ${unit}" || bad "unit: ${unit} (rerun: RM_FIXTURE_DIR=${HERE}/test/fixtures RM_CATALOG_DIR=${HERE}/faceplates node ${DIST}/manager/asset-manager/test/unit/${unit}.test.js)"
done

# ── the CLI against a fixture config ─────────────────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/rm-fix.XXXXXX")"
trap 'rm -rf "${FIX}" "${DIST}"' EXIT
export CMDB_SOCKET="${FIX}/no-cmdb.sock"
unset CMDB_URL TAPPAAS_JOB
mkdir -p "${FIX}/cfg"
TOPO="${HERE}/test/fixtures/topology-hrossen.json"
USW="USW Pro XG 10 PoE"
# Both config spellings: TS reads TAPPAAS_CONFIG first, and an inherited one
# would point this suite at the live config. The catalog is the fixture's.
RM() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" TAPPAAS_FACEPLATES="${HERE}/test/fixtures/faceplates" \
    run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
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
[[ "$(RM device list --json 2>/dev/null | jq -r '.[0].ports | map("\(.name):\(.kind):\(.speed)") | join(",")')" == "WAN:rj45:1g,LAN 1:rj45:1g" ]] && ok "device list --json (asset list): its ports from its model, rj45 at 1g" || bad "device list"
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
[[ -z "$(ls -A "${FIX}/cfg" | grep -v '^positions.json$' | grep -v '^site.json$' | grep -v '^.cmdb-spool$')" ]] && ok "no lock or temp file left behind" || bad "left behind: $(ls -A "${FIX}/cfg")"
SPOOL="${FIX}/cfg/.cmdb-spool"
[[ "$(cat "${SPOOL}"/*.json 2>/dev/null | jq -s '[.[] | select(.kind == "change" and .source == "asset-manager")] | length')" -gt 5 ]] && ok "the changing verbs' reports spooled (no cmdb-controller here), the verbs done" || bad "no change reports spooled"
[[ "$(cat "${SPOOL}"/*.json | jq -rs '[.[] | select(.verb == "room add")][0].objects | map("\(.class) \(.name)") | join(",")')" == "location far,room shed" ]] && ok "room add: a change naming the room and its location (a room added before site.json named none: left to report)" || bad "room add's change: $(cat "${SPOOL}"/*.json | jq -cs '[.[] | select(.verb == "room add")][0]')"
[[ "$(cat "${SPOOL}"/*.json | jq -rs '[.[] | select(.verb == "unplace")] | map(.relations[] | select(.end) | .type) | unique | join(",")')" == "placed-in" ]] && ok "unplace: the placed-in relation ended" || bad "unplace's change"
[[ "$(cat "${SPOOL}"/*.json | jq -rs '[.[] | select(.verb | test("^faceplate"))] | length')" == "0" ]] && ok "faceplate verbs: nothing the CMDB holds, no report" || bad "a faceplate verb reported"
# report: hrossen's positions.json as migration 0027 leaves it.
RC="${FIX}/report"; mkdir -p "${RC}"
cp "${HERE}/../../scripts/test/fixtures/0027-hrossen/positions-after.json" "${RC}/positions.json"
cp "${HERE}/test/fixtures/site-hrossen.json" "${RC}/site.json"
RR() { CONFIG_DIR="${RC}" TAPPAAS_CONFIG="${RC}" TAPPAAS_FACEPLATES="${HERE}/faceplates" run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
_r="$(RR report --json 2>/dev/null)"
[[ "$(jq -r '"\(.report.source) \(.report.kind) \(.report.objects | all(.recorded)) \(.skipped | length)"' <<<"${_r}")" == "asset-manager observation true 0" ]] && ok "report --json: one observation from asset-manager, every object recorded, nothing left out" || bad "report --json: ${_r:0:300}"
[[ "$(jq -r '[.report.objects[] | select(.class != "port") | "\(.class)/\(.name)"] | sort | join(",")' <<<"${_r}")" == "appliance/ISP modem,location/knudanchersvej95,network-device/ap-01,network-device/sw-01,network-device/sw-02,network-device/sw-03,other-device/printer,passive-device/patchpanel1,rack/rack1,room/basement,room/stue,server/srv-01,server/srv-02,server/srv-03" ]] \
    && ok "report --json: the rooms, the rack, each asset as its class" || bad "report --json classes: $(jq -c '[.report.objects[] | select(.class != "port") | .class]' <<<"${_r}")"
[[ "$(jq -r '[.report.relations[].type] | group_by(.) | map("\(.[0]):\(length)") | join(",")' <<<"${_r}")" == "connects:2,placed-in:8" ]] && ok "report --json: 8 placements, 2 cables" || bad "report --json relations"
[[ "$(jq -r '[.allocations[].relations[0] | "\(.from.name)>\(.to.class)/\(.to.name)"] | map(select(startswith("srv-01"))) | join(",")' <<<"${_r}")" == "srv-01>node/tappaas1" ]] && ok "report --json: srv-01 allocated to the node tappaas1" || bad "report --json allocations"
RR report >/dev/null 2>&1 && [[ "$(ls "${RC}/.cmdb-spool"/*.json | wc -l | tr -d ' ')" == "11" ]] && ok "report: no cmdb-controller — the batch and its 10 allocations spooled, exit 0" || bad "report: spool $(ls "${RC}/.cmdb-spool" 2>&1)"
_e="$(CONFIG_DIR="${RC}" TAPPAAS_CONFIG="${RC}" TAPPAAS_FACEPLATES="${HERE}/faceplates" run_ts "node '${DIST}/manager/asset-manager/src/main.js' export --json --cmdb" 2>/dev/null)"
[[ "$(jq -r '"\(.objects | map(select(.class == "rack")) | length) \(.relations | map(select(.type == "allocated-to")) | length) \(.catalog | length > 5)"' <<<"${_e}")" == "1 10 true" ]] && ok "export --cmdb: the objects and relations as the CMDB answers, with the catalog" || bad "export --cmdb: ${_e:0:300}"
# The catalog as shipped, through the CLI.
RMC() { CONFIG_DIR="${FIX}/cfg" TAPPAAS_CONFIG="${FIX}/cfg" TAPPAAS_FACEPLATES="${HERE}/faceplates" \
    run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
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
RMC faceplates list 2>/dev/null | grep 'acme/nas-4' | grep -c site >/dev/null && ok "faceplates list: marked site" || bad "faceplates list: the mark"
[[ "$(RMC faceplates show acme/nas-4 --file 2>/dev/null | jq -r '"\(.vendor) \(.model) \(.ports)"')" == "acme NAS 4 4xrj45, 2xsfp+" ]] && ok "faceplates show --file: the plate as a catalog file" || bad "faceplates show --file"
[[ "$(RMC export --json 2>/dev/null | jq -r '[.catalog[] | select(.site) | .key] | join(",")')" == "acme/nas-4" ]] && ok "export: the site's plate in the catalog" || bad "export: the site's plate"
RMC faceplate add generic/patch-panel-24 --units 1 --ports "24xrj45[2-98]" --kind patch-panel --passive >/dev/null 2>&1 && ok "faceplate add: a shipped key" || bad "faceplate add: a shipped key"
RMC validate 2>&1 | grep -c "overrides the shipped one" >/dev/null && ok "validate: the override pointed out" || bad "validate: the override"
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
RM device record "${USW}:8" --name printer --kind other --topology "${SEEN}" --check >/dev/null 2>&1 && [[ "$(jq -r '.assets.printer // "none"' "${DOC}")" == "none" ]] && ok "device record --check: nothing written" || bad "device record --check"
RM device record "${USW}:9" --name printer --kind other --topology "${SEEN}" >/dev/null 2>&1 && bad "device record: a port that sees nothing refused" || ok "device record: a port that sees nothing refused"
RM device record aa:bb:cc:00:11:22 --name printer --kind other --topology "${SEEN}" >/dev/null 2>&1 && ok "device record <mac>" || bad "device record <mac>"
[[ "$(jq -r '.assets.printer | "\(.ports[0].mac) \(.ports | map(.name) | join(",")) \(.displayName) \(.role)"' "${DOC}")" == "aa:bb:cc:00:11:22 eth0 printer-1 printer" ]] && ok "device record (asset record): its MAC on its LLDP port, its name kept, playing itself" || bad "device record: the record"
[[ "$(jq -r --arg sw "${USW}" '[.cables[] | select(.from.device == $sw and .from.port == "8") | .to | "\(.device):\(.port)"] | join(",")' "${DOC}")" == "printer:eth0" ]] && ok "device record: the port's cable recorded" || bad "device record: the cable"
RM device record "${USW}:8" --name printer2 --kind other --topology "${SEEN}" >/dev/null 2>&1 && bad "device record: a port with a recorded cable refused" || ok "device record: a port with a recorded cable refused"
RM cable remove "${USW}:8" >/dev/null 2>&1 && RM device remove printer >/dev/null 2>&1 || bad "device record: undone"
# A site the migration has not reached: racks.json is read, never written.
LEG="$(mktemp -d "${TMPDIR:-/tmp}/rm-leg.XXXXXX")"
printf '{"version":1,"racks":{"r1":{"units":10,"width":"19in","numbering":"bottom-up"}}}' > "${LEG}/racks.json"
RML() { CONFIG_DIR="${LEG}" TAPPAAS_CONFIG="${LEG}" TAPPAAS_FACEPLATES="${HERE}/test/fixtures/faceplates" \
    run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
[[ "$(RML rack list --json 2>/dev/null | jq -r '.[0].name')" == "r1" ]] && ok "racks.json read while the migration has not run" || bad "racks.json not read"
RML rack add r2 >/dev/null 2>&1 && bad "a write beside racks.json refused" || ok "a write beside racks.json refused"
[[ ! -e "${LEG}/positions.json" ]] && ok "nothing written beside racks.json" || bad "positions.json written beside racks.json"
rm -rf -- "${LEG}"
# ── assets: a box's life, ordered to disposed (ADR-040 D7-D9) ─────────
AC="${FIX}/assets"; mkdir -p "${AC}"
RA() { CONFIG_DIR="${AC}" TAPPAAS_CONFIG="${AC}" TAPPAAS_FACEPLATES="${HERE}/faceplates" TAPPAAS_JOB="${RA_JOB:-}" \
    run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
ASP="${AC}/.cmdb-spool"
AD="${AC}/positions.json"
RA rack add rack1 >/dev/null 2>&1 || bad "assets: rack add"
RA asset add --kind server --vendor HP --model "Z840" --serial CZC1 --stage ordered --supplier "Proshop" --purchase-date 2026-10-01 --ownership owned --topology "${TOPO}" >/dev/null 2>&1 \
    && [[ "$(jq -r '.assets["srv-01"] | "\(.kind) \(.stage) \(.serial) \(.procurement.supplier) \(.procurement.ownership)"' "${AD}")" == "server ordered CZC1 Proshop owned" ]] \
    && ok "asset add: no name is the next tag of its kind (srv-01), ordered, with its procurement" || bad "asset add srv-01"
RA asset add --kind server --serial CZC1 --topology "${TOPO}" >/dev/null 2>&1 && bad "asset add: a serial another asset has refused" || ok "asset add: a serial another asset has refused"
RA asset add tappaas1 --kind server --topology "${TOPO}" >/dev/null 2>&1 && bad "asset add: a name the topology has refused (it is a role)" || ok "asset add: a name the topology has refused (it is a role)"
RA asset add --kind server --ownership leased --topology "${TOPO}" >/dev/null 2>&1 && bad "asset add: an ownership not owned or rented refused" || ok "asset add: an ownership not owned or rented refused"
RA place srv-01 --rack rack1 --u 1 --topology "${TOPO}" >/dev/null 2>&1 && bad "place: an ordered asset refused" || ok "place: an ordered asset refused (receive it first)"
RA asset receive srv-01 >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"].stage' "${AD}")" == "stock" ]] && ok "asset receive: ordered → stock" || bad "asset receive"
RA asset receive srv-01 >/dev/null 2>&1 && bad "asset receive: only an ordered one" || ok "asset receive: only an ordered one"
RA port add srv-01 eno1 --kind rj45 --role lan --mac aa:bb:cc:00:00:01 >/dev/null 2>&1 && RA port add srv-01 ilo --kind rj45 --role bmc --mac aa:bb:cc:00:00:02 >/dev/null 2>&1 \
    && RA port add srv-01 sfp1 --kind sfp --speed 10g --module dac >/dev/null 2>&1 \
    && [[ "$(jq -r '.assets["srv-01"].ports | map("\(.name):\(.kind):\(.speed // "-"):\(.role // .module // "-")") | join(",")' "${AD}")" == "eno1:rj45:1g:lan,ilo:rj45:1g:bmc,sfp1:sfp:10g:dac" ]] \
    && ok "port add: an rj45 at 1g by default, a BMC by its role, an SFP+ cage with its module" || bad "port add"
RA port add srv-01 usb1 --kind usb-a --speed 10g >/dev/null 2>&1 && bad "port add: a speed its connector lacks refused" || ok "port add: a speed its connector lacks refused (usb-a 10g)"
RA port add srv-01 wl0 --kind wifi --standard wifi6 --bands 2.4,5,6 >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"].ports[3].bands | join(",")' "${AD}")" == "2.4,5,6" ]] && ok "port add: wifi with its standard and bands" || bad "port add wifi"
RA port add srv-01 wl1 --kind wifi --speed 1g >/dev/null 2>&1 && bad "port add: a wifi port with a speed refused" || ok "port add: a wifi port with a speed refused"
RA port add srv-01 eth9 --kind rj45 --module sr >/dev/null 2>&1 && bad "port add: a module outside an sfp cage refused" || ok "port add: a module outside an sfp cage refused"
RA port add srv-01 eth8 --kind rj45 --mac aa:bb:cc:00:00:01 >/dev/null 2>&1 && bad "port add: a MAC another port has refused" || ok "port add: a MAC another port has refused (MACs unique)"
RA port modify srv-01 eno1 --set speed=2.5g >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"].ports[0].speed' "${AD}")" == "2.5g" ]] && ok "port modify: its speed" || bad "port modify"
RA port modify srv-01 eno1 --set speed=25g >/dev/null 2>&1 && bad "port modify: rj45 at 25g refused" || ok "port modify: rj45 at 25g refused"
RA port remove srv-01 wl0 >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"].ports | length' "${AD}")" == "3" ]] && ok "port remove" || bad "port remove"
RA place srv-01 --rack rack1 --u 1 --faceplate generic/server-2u --topology "${TOPO}" >/dev/null 2>&1 && [[ "$(jq -r '"\(.assets["srv-01"].stage) \(.placements["srv-01"].u)"' "${AD}")" == "placed 1" ]] \
    && ok "place: an asset in stock by its own name, placed" || bad "place srv-01"
RA validate --topology "${TOPO}" >/dev/null 2>&1 && ok "validate: a placed asset with no role is valid (the rack draws it)" || bad "validate: placed asset"
RA asset allocate srv-01 --role crs-a --topology "${TOPO}" >/dev/null 2>&1 && bad "asset allocate: a server to a switch refused" || ok "asset allocate: a server to a switch refused"
RA asset allocate srv-01 --role tappaas9 --topology "${TOPO}" >/dev/null 2>&1 && bad "asset allocate: a node the topology lacks refused" || ok "asset allocate: a node the topology lacks refused"
RA asset allocate srv-01 --role tappaas1 --topology "${TOPO}" >/dev/null 2>&1 \
    && [[ "$(jq -r '"\(.assets["srv-01"].role) \(.placements.tappaas1.u) \(.placements["srv-01"] // "moved")"' "${AD}")" == "tappaas1 1 moved" ]] \
    && ok "asset allocate: the role tappaas1, its placement now under the role's name" || bad "asset allocate"
[[ "$(cat "${ASP}"/*.json | jq -rs '[.[] | select(.verb == "asset allocate")] | map("\(.kind) \(.objects // [] | map(.name) | join("+")) \(.relations // [] | map("\(.type):\(.to.class)/\(.to.name)") | join("+"))") | join(",")')" == "change srv-01 ,change  allocated-to:node/tappaas1" ]] \
    && ok "asset allocate: a change (the asset, now operational) and the allocation to the node apart" || bad "asset allocate's reports: $(cat "${ASP}"/*.json | jq -cs '[.[] | select(.verb == "asset allocate")]')"
[[ "$(RA asset list --json 2>/dev/null | jq -r '.[0] | "\(.stage) \(.placed)"')" == "operational rack1 U1-U2 front" ]] && ok "asset list: operational (it has a role), placed" || bad "asset list: stage"
[[ "$(RA asset show tappaas1 --json 2>/dev/null | jq -r '.name')" == "srv-01" ]] && ok "asset show: by the role it plays" || bad "asset show <role>"
RA cable add --from "${USW}:5" --to "srv-01:sfp1" --link-speed 1g --topology "${TOPO}" >/dev/null 2>&1 \
    && [[ "$(jq -r '.cables[0] | "\(.to.device):\(.to.port) \(.linkSpeed)"' "${AD}")" == "tappaas1:sfp1 1g" ]] && ok "cable add: an asset's end under its role, the link speed seen (a 10g cage at 1g)" || bad "cable add --link-speed"
RA asset fault srv-01 --note "fan 2 failed" >/dev/null 2>&1 && [[ "$(RA asset list --json 2>/dev/null | jq -r '.[0] | "\(.stage) \(.faulty) \(.faultNote)"')" == "operational true fan 2 failed" ]] \
    && ok "asset fault: faulty beside the stage, operational and faulty" || bad "asset fault"
RA asset fault srv-01 >/dev/null 2>&1 && bad "asset fault: a note is required" || ok "asset fault: a note is required"
RA asset dispose srv-01 --how sold >/dev/null 2>&1 && bad "asset dispose: refused while it has a role" || ok "asset dispose: refused while it has a role"
RA_JOB=20261030101500-abc123 RA asset release srv-01 >/dev/null 2>&1 && [[ "$(jq -r '"\(.assets["srv-01"].role // "none") \(.placements["srv-01"].u) \(.cables[0].to.device)"' "${AD}")" == "none 1 srv-01" ]] \
    && ok "asset release: the role ends, the placement and its cable stay with the box under its name" || bad "asset release"
[[ "$(cat "${ASP}"/*.json | jq -rs '[.[] | select(.verb == "asset release")] | map("\(.job) \(.objects | map("\(.name):\(.attributes.stage):\(.attributes.allocatedTo)") | join("+"))") | join(",")')" == "20261030101500-abc123 srv-01:placed:null" ]] \
    && ok "asset release: one change with the console's job id, the asset placed and unallocated" || bad "asset release's report: $(cat "${ASP}"/*.json | jq -cs '[.[] | select(.verb == "asset release")]')"
[[ "$(RA asset list --stage placed --json 2>/dev/null | jq -r 'map(.name) | join(",")')" == "srv-01" ]] && ok "asset list --stage placed: back to placed" || bad "asset list --stage"
RA asset repaired srv-01 >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"] | "\(.faulty // "-") \(.faultNote // "-")"' "${AD}")" == "- -" ]] && ok "asset repaired: the flag and its note cleared" || bad "asset repaired"
RA asset dispose srv-01 --how recycled >/dev/null 2>&1 && bad "asset dispose: refused while placed" || ok "asset dispose: refused while placed"
RA cable remove "srv-01:sfp1" >/dev/null 2>&1 && RA unplace srv-01 >/dev/null 2>&1 && [[ "$(jq -r '.assets["srv-01"].stage' "${AD}")" == "stock" ]] && ok "unplace: the asset is in stock again" || bad "unplace srv-01"
RA asset dispose srv-01 --how teleported >/dev/null 2>&1 && bad "asset dispose: an unknown how refused" || ok "asset dispose: an unknown how refused"
RA asset dispose srv-01 --how recycled --wiped --when 2026-10-29 >/dev/null 2>&1 \
    && [[ "$(jq -r '.assets["srv-01"] | "\(.stage) \(.disposal.how) \(.disposal.when) \(.disposal.wiped)"' "${AD}")" == "disposed recycled 2026-10-29 true" ]] && ok "asset dispose: how, when, disks wiped; the record stays" || bad "asset dispose"
RA asset allocate srv-01 --role tappaas2 --topology "${TOPO}" >/dev/null 2>&1 && bad "asset allocate: a disposed asset refused" || ok "asset allocate: a disposed asset refused"
RA asset remove srv-01 >/dev/null 2>&1 && bad "asset remove: a disposed record stays" || ok "asset remove: a disposed record stays"
RA asset add --kind switch --model unifi/usw-pro-xg-10-poe --topology "${TOPO}" >/dev/null 2>&1 && RA asset add --kind access-point --topology "${TOPO}" >/dev/null 2>&1 && RA asset add --kind modem --topology "${TOPO}" >/dev/null 2>&1 \
    && [[ "$(jq -r '.assets | keys | join(",")' "${AD}")" == "ap-01,dev-01,srv-01,sw-01" ]] && ok "asset add: a tag per kind — sw-01, ap-01, dev-01" || bad "asset add: the tags"
[[ "$(RA asset show sw-01 --json 2>/dev/null | jq -r '[.ports[] | select(.name == "1" or .name == "11") | "\(.name):\(.kind):\(.speed)"] | join(",")')" == "1:rj45:10g,11:sfp:10g" ]] \
    && ok "asset show: a model's ports from its plate, kind and speed per port (10G RJ45, SFP+)" || bad "asset show: the plate's ports"
RA asset allocate sw-01 --role "${USW}" --topology "${TOPO}" >/dev/null 2>&1 && RA validate --topology "${TOPO}" >/dev/null 2>&1 && ok "asset allocate: a switch asset to the switch, valid" || bad "asset allocate sw-01"
RA asset modify dev-01 --set role=x >/dev/null 2>&1 && bad "asset modify: the role is allocate's" || ok "asset modify: the role is allocate's"
RA asset modify dev-01 --set procurement.warrantyUntil=2028-01-01 --set assetTag=T-17 >/dev/null 2>&1 && [[ "$(jq -r '.assets["dev-01"] | "\(.procurement.warrantyUntil) \(.assetTag)"' "${AD}")" == "2028-01-01 T-17" ]] && ok "asset modify: its tag and its warranty" || bad "asset modify"
# A positions.json from before migration 0027 is read, never written.
OLDD="$(mktemp -d "${TMPDIR:-/tmp}/rm-old.XXXXXX")"
printf '{"version":1,"devices":{"ISP modem":{"kind":"modem","ports":["WAN","LAN 1"],"mac":"aa:bb:cc:00:00:09"}},"cables":[{"from":{"device":"%s","port":"5"},"to":{"device":"ISP modem","port":"LAN 1"},"kind":"uplink"}]}' "${USW}" > "${OLDD}/positions.json"
RO() { CONFIG_DIR="${OLDD}" TAPPAAS_CONFIG="${OLDD}" TAPPAAS_FACEPLATES="${HERE}/faceplates" run_ts "node '${DIST}/manager/asset-manager/src/main.js' $(printf "'%s' " "$@")"; }
[[ "$(RO asset list --json 2>/dev/null | jq -r '.[0] | "\(.name) \(.role) \(.stage) \([.ports[] | select(.mac) | .name] | join(","))"')" == "ISP modem ISP modem operational LAN 1" ]] \
    && ok "an unmigrated devices{} reads as assets: each playing itself, its MAC on its cabled port" || bad "devices{} read as assets"
RO room add basement >/dev/null 2>&1 && bad "a write before migration 0027 refused" || ok "a write before migration 0027 refused"
rm -rf -- "${OLDD}"
RM --help --json 2>/dev/null | jq -e '.verbs | length > 10' >/dev/null && ok "--help --json is the verb manifest" || bad "--help --json"

rm -rf -- "${DIST}"
echo ""
echo "asset-manager test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
