#!/usr/bin/env bash
#
# Unit tests for ap-manager's reports to the CMDB (ADR-040 D4): the payload
# cmdb-report.jq builds from fixture desired, actual and positions files
# (classes, keys, relations), and, where ap-manager itself runs (tappaas-cicd:
# it sources /home/tappaas/bin), `report --json` and a changing verb's report
# carrying the console's job id, through a fake `cmdb` CLI.
#
# Usage: ./test-cmdb-report.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FX="${HERE}/test/fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

build() { # build <only> <ended> <ended-ssids> <kind> <verb> <job>
    jq --argjson actual "$(cat "${FX}/actual.json")" --argjson pos "$(cat "${FX}/positions.json")" --arg only "$1" \
       --argjson ended "$2" --argjson endedSsids "$3" --arg source ap-manager --arg kind "$4" --arg verb "$5" --arg job "$6" --arg actor "" \
       -f "${HERE}/cmdb-report.jq" "${FX}/desired.json"
}

echo "test-cmdb-report (ap-manager):"
R="$(build "" '[]' '[]' observation "" "")"
core() { jq -c ".[0] | $1" <<<"${R}"; }
ck "an array of reports from ap-manager"         "true" "$(jq -c 'type == "array" and all(.[]; .source == "ap-manager" and .kind == "observation")' <<<"${R}")"
ck "each AP is a device CI"                      '["Attic","Nano HD"]' "$(core '[.objects[] | select(.class == "device") | .name] | sort')"
ck "…with what it answered (firmware, controller)" '["6.6.77","unifi-controller"]' "$(core '.objects[] | select(.class == "device" and .name == "Nano HD") | .attributes | [.firmware, .controller]')"
ck "its asset: the record's tag, vendor, serial"  '["ap-01","ubiquiti","AP0001","access-point"]' \
   "$(core '.objects[] | select(.class == "network-device" and .attributes.serial != null) | [.name, .attributes.vendor, .attributes.serial, .attributes.deviceType]')"
ck "an AP with no record: named as the AP"       '"Attic"' "$(core '[.objects[] | select(.class == "network-device")] | map(.name) | map(select(. == "Attic")) | .[0]')"
ck "the asset is allocated-to its device"        'true' "$(core 'any(.relations[]; .type == "allocated-to" and .from == "asset:ap-01" and .to == "device:Nano HD")')"
ck "the record's ports: an rj45 uplink and a wifi radio" '[["eth0","rj45"],["radio","wifi"]]' \
   "$(core '[.objects[] | select(.class == "port" and .attributes.asset.ref == "asset:ap-01") | [.name, .attributes.kind]]')"
ck "…the radio's standard and bands"             '["wifi5",["2.4","5"]]' "$(core '.objects[] | select(.ref == "port:ap-01/radio") | .attributes | [.standard, .bands]')"
ck "no record: uplink (rj45, 1g) and wifi"       '[["uplink","rj45","1g"],["wifi","wifi",null]]' \
   "$(core '[.objects[] | select(.class == "port" and .attributes.asset.ref == "asset:Attic") | [.name, .attributes.kind, .attributes.speed]]')"
ck "each SSID: security, zone, the APs that broadcast it" '["wpa3-personal","home",["Attic","Nano HD"]]' \
   "$(core '.objects[] | select(.class == "ssid" and .name == "Home") | .attributes | [.security, .zone, .broadcastOn]')"
ck "a radio connects to each SSID its AP broadcasts" '["ssid:Guest","ssid:Home"]' \
   "$(core '[.relations[] | select(.type == "connects" and .from == "port:Attic/wifi") | .to] | sort')"
ck "…and not to one it does not"                 'false' "$(core 'any(.relations[]; .from == "port:ap-01/radio" and .to == "ssid:Guest")')"
ck "Wi-Fi clients are not reported (no MAC resolution yet)" 'false' "$(jq -c 'tostring | test("aa:bb:cc:dd:ee:99")' <<<"${R}")"
ck "the uplink cable is a report of its own"     '2' "$(jq -c 'length' <<<"${R}")"
ck "…to the switch's port on its asset (by tag)" '["9","sw-01"]' \
   "$(jq -c '.[1] | [(.objects[] | select(.ref == "swport") | .name), (.objects[] | select(.ref == "swasset") | .name)]' <<<"${R}")"

C="$(build "Nano HD" '["Old AP"]' '["Gone"]' change "ap-manager ssid remove" job-7)"
ck "a change carries the verb and the job"       '["change","ap-manager ssid remove","job-7"]' "$(jq -c '.[0] | [.kind, .verb, .job]' <<<"${C}")"
ck "…only the AP it touched, and its SSIDs"      '[["device","Nano HD"],["ssid","Home"]]' \
   "$(jq -c '[.[0].objects[] | select((.class == "device" or .class == "ssid") and (.end | not)) | [.class, .name]] | sort' <<<"${C}")"
ck "…and ends what the verb removed"             '[["device","Old AP"],["ssid","Gone"]]' "$(jq -c '[.[0].objects[] | select(.end) | [.class, .name]]' <<<"${C}")"

# ── report --discover (ADR-040 D15) ──
D="$(jq --argjson actual "$(cat "${FX}/actual.json")" --argjson pos "$(cat "${FX}/positions.json")" --arg only "" \
    --argjson ended '[]' --argjson endedSsids '[]' --arg source ap-manager --arg kind observation --arg verb "" --arg job "" --arg actor "" \
    --argjson discover true -f "${HERE}/cmdb-report.jq" "${FX}/desired.json")"
deep() { jq -c ".[-1] | $1" <<<"${D}"; }
ck "--discover adds one report at the end"       "$(( $(jq 'length' <<<"${R}") + 1 ))" "$(jq 'length' <<<"${D}")"
ck "a radio: standard, band, channel, power"     '["wifi5",["5"],36,20]' "$(deep '.objects[] | select(.name == "ra0") | .attributes | [.standard, .bands, .channel, .power]')"
ck "a radio with no name is named by its band; an unknown standard is left out" '[["2.4"],null]' "$(deep '.objects[] | select(.name == "radio-2.4") | .attributes | [.bands, .standard]')"
ck "a client: MAC, SSID, signal"                 '{"mac":"aa:bb:cc:dd:ee:99","ssid":"Home","signal":-61}' "$(deep '.objects[] | select(.class == "device" and .name == "Nano HD") | .attributes.clients[0]')"
ck "an SSID desired does not declare is found"   '["Nano HD"]' "$(deep '.objects[] | select(.class == "ssid" and .name == "Rogue") | .attributes.broadcastOn')"
ck "each radio connects to what it broadcasts"   '4' "$(deep '[.relations[] | select(.type == "connects")] | length')"
ck "firmware and uptime"                         '["6.6.77",3600]' "$(deep '.objects[] | select(.class == "device" and .name == "Nano HD") | .attributes | [.firmware, .uptime]')"

# ── the CLI (where ap-manager runs) ──
if [[ -r /home/tappaas/bin/common-install-routines.sh ]]; then
    export CONFIG_DIR="${TMP}"
    cp "${FX}/desired.json" "${TMP}/switch-configuration-desired.json"
    cp "${FX}/actual.json" "${TMP}/switch-configuration-actual.json"
    cp "${FX}/positions.json" "${TMP}/positions.json"
    echo '{"mgmt": {"type": "Management", "vlantag": 0}, "home": {"type": "Client", "state": "Active", "vlantag": 310, "SSID": "Home"}, "guest": {"type": "Guest", "state": "Active", "vlantag": 600, "SSID": "Guest"}}' > "${TMP}/zones.json"
    printf '#!/usr/bin/env bash\n[[ "$1" == report ]] && cat >> "%s/sent.jsonl" && echo >> "%s/sent.jsonl"\nexit 0\n' "${TMP}" "${TMP}" > "${TMP}/cmdb"
    chmod +x "${TMP}/cmdb"
    export CMDB_BIN="${TMP}/cmdb" TAPPAAS_JOB_ID=job-42 TAPPAAS_CMDB=
    ck "report --json prints what the filter builds" "$(jq -c . <<<"${R}")" "$("${HERE}/ap-manager" report --json 2>/dev/null | jq -c .)"
    "${HERE}/ap-manager" modify Attic --description "attic, north wall" >/dev/null 2>&1
    ck "modify reports a change with the console's job id" '"job-42"' "$(jq -sc 'map(select(.kind == "change")) | .[0].job' "${TMP}/sent.jsonl" 2>/dev/null)"
else
    echo "  SKIP: the CLI checks (ap-manager runs on tappaas-cicd only)"
fi

echo ""
echo "test-cmdb-report (ap-manager): ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
