#!/usr/bin/env bash
#
# Unit tests for switch-manager's reports to the CMDB (ADR-040 D4): the
# payload cmdb-report.jq builds from fixture actual + positions files (classes,
# keys, relations), and, where switch-manager itself runs (tappaas-cicd: it
# sources /home/tappaas/bin), `report --json` and a changing verb's report
# carrying the console's job id, through a fake `cmdb` CLI.
#
# Usage: ./test-cmdb-report.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FX="${HERE}/test/fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

build() { # build <only> <ended-json> <kind> <verb> <job>
    jq --argjson pos "$(cat "${FX}/positions.json")" --arg only "$1" --argjson ended "$2" --arg source switch-manager \
       --arg kind "$3" --arg verb "$4" --arg job "$5" --arg actor "" -f "${HERE}/cmdb-report.jq" "${FX}/actual.json"
}

echo "test-cmdb-report:"
ck "a switch names what topology reads"            '["switch","unifi","auto"]' \
   "$(build "" '[]' observation "" "" | jq -c '.[0].objects[] | select(.ref == "device:core") | .attributes | [.deviceType, .vendor, .managed]')"
ck "…and the MLAG pair it is in"                   '"core+edge"' \
   "$(build "" '[]' observation "" "" | jq -c '.[0].objects[] | select(.ref == "device:core") | .attributes.mlag.pair.name')"
ck "a row is no assignment without list-ports"     'false' "$(build "" '[]' observation "" "" | jq -c 'tostring | test("assignment")')"
R="$(build "" '[]' observation "" "")"
core() { jq -c ".[0] | $1" <<<"${R}"; }
ck "an array of reports, from switch-manager"      "true" "$(jq -c 'type == "array" and all(.[]; .source == "switch-manager" and .kind == "observation")' <<<"${R}")"
ck "each switch is a device CI"                    '["core","edge"]' "$(core '[.objects[] | select(.class == "device") | .name]')"
ck "…with model, firmware, address, controller"    '["USWED77","7.1.66","10.0.0.201","unifi-controller"]' \
   "$(core '.objects[] | select(.class == "device" and .name == "core") | .attributes | [.model, .firmware, .managementAddress, .controller]')"
ck "its asset is named by the positions record's tag" '["sw-01","edge"]' "$(core '[.objects[] | select(.class == "network-device") | .name]')"
ck "…keyed by the record's vendor and serial"      '["ubiquiti","F4E2C6000001"]' "$(core '.objects[] | select(.name == "sw-01") | .attributes | [.vendor, .serial]')"
ck "a disposed record names no switch"             '"mikrotik"' "$(core '.objects[] | select(.class == "network-device" and .name == "edge") | .attributes.vendor')"
ck "the asset is allocated-to its device"          'true' "$(core 'any(.relations[]; .type == "allocated-to" and .from == "asset:sw-01" and .to == "device:core")')"
ck "every port is part-of its asset"               'true' "$(core '[.objects[] | select(.class == "port")] | length == 10 and all(.attributes.asset.ref | startswith("asset:"))')"
ck "a port's kind and speed: the actual's maxSpeed" '["rj45","10g"]' "$(core '.objects[] | select(.ref == "port:sw-01/1") | .attributes | [.kind, .speed]')"
ck "…else the record's (an SFP cage)"              '["sfp","10g"]' "$(core '.objects[] | select(.ref == "port:sw-01/11") | .attributes | [.kind, .speed]')"
ck "…else rj45, its speed the plate's (asset-manager)" '["rj45",null]' "$(core '.objects[] | select(.ref == "port:sw-01/2") | .attributes | [.kind, .speed]')"
ck "an SFP port keeps its module"                  '"dac"' "$(core '.objects[] | select(.ref == "port:sw-01/peer") | .attributes.module')"
ck "a recorded cable between switches, seen by LLDP too, is one connects" '1' \
   "$(core '[.relations[] | select(.type == "connects" and ([.from, .to] | sort) == ["port:edge/ether1","port:sw-01/2"])] | length')"
ck "…with the observed link speed"                 '"1g"' "$(core '.relations[] | select(.from == "port:edge/ether1") | .attributes.linkSpeed')"
ck "the MLAG peer link is a cable"                 'true' "$(core 'any(.relations[]; .attributes.origin == "mlag-peer")')"
ck "…in the pair's peer-link redundancy group"     '"core+edge:peer"' "$(core '.relations[] | select(.attributes.origin == "mlag-peer") | .attributes.redundancyGroup')"
ck "a cable between switches outside a redundancy has no group" 'null' \
   "$(core '.relations[] | select(.type == "connects" and ([.from, .to] | sort) == ["port:edge/ether1","port:sw-01/2"]) | .attributes.redundancyGroup')"
ck "the two legs of an MLAG LAG: one group, <pair>:<lag>" '["core+edge:lag-t1","core+edge:lag-t1"]' \
   "$(jq -c '[.[1:][] | .relations[] | select(.from == "port:sw-01/1" or .from == "port:edge/ether3") | .attributes.redundancyGroup]' <<<"${R}")"
ck "…a NIC cable on a port in no MLAG LAG has none" 'null' \
   "$(jq -c '.[1:][] | .relations[] | select(.from == "port:edge/ether2") | .attributes.redundancyGroup' <<<"${R}")"
ck "a MAC seen behind a port is not reported (no MAC resolution yet)" 'false' "$(jq -c 'tostring | test("aa:bb:cc:dd:ee:01"; "i")' <<<"${R}")"
ck "a cable to a node's NIC is a report of its own" '3' "$(jq -c 'length - 1' <<<"${R}")"
ck "…its NIC is a port on the node's server asset" '{"class":"server","name":"srv-01"}' \
   "$(jq -c '.[] | .objects[] | select(.name == "enp1s0") | .attributes.asset' <<<"${R}")"
ck "…the LLDP neighbour that is a node, too"       '"srv-02"' "$(jq -c '.[] | .objects[] | select(.name == "eno1") | .attributes.asset.name' <<<"${R}")"

C="$(build core '["gone"]' change "switch-manager modify-switch" job-7)"
ck "a change carries the verb and the job"         '["change","switch-manager modify-switch","job-7"]' "$(jq -c '.[0] | [.kind, .verb, .job]' <<<"${C}")"
ck "…only the switch it touched"                   '["core"]' "$(jq -c '[.[0].objects[] | select(.class == "device" and (.end | not)) | .name]' <<<"${C}")"
ck "…and ends a removed one"                       '["gone"]' "$(jq -c '[.[0].objects[] | select(.end) | .name]' <<<"${C}")"

# ── report --discover (ADR-040 D15) ──
D="$(jq --argjson pos "$(cat "${FX}/positions.json")" --arg only "" --argjson ended '[]' --arg source switch-manager \
    --arg kind observation --arg verb "" --arg job "" --arg actor "" --argjson discover true \
    --argjson zones '{"_doc": "x", "srv": {"vlantag": 200}, "mgmt": {"vlantag": 0}}' -f "${HERE}/cmdb-report.jq" "${FX}/actual.json")"
deep() { jq -c ".[-1] | $1" <<<"${D}"; }
ck "--discover adds one report at the end"          "$(( $(jq 'length' <<<"${R}") + 1 ))" "$(jq 'length' <<<"${D}")"
ck "…the plain reports are unchanged"               "$(jq -c . <<<"${R}")" "$(jq -c '.[:-1]' <<<"${D}")"
ck "every port is in it, an unused one too"         '10' "$(deep '[.objects[] | select(.class == "port")] | length')"
ck "an unused port: its link state"                 '"down"' "$(deep '.objects[] | select(.class == "port" and .name == "11") | .attributes.link')"
ck "a port's negotiated speed, PoE and STP state"   '["10g",7.5,"forwarding"]' "$(deep '.objects[] | select(.class == "port" and .name == "1") | .attributes | [.linkSpeed, .poe.watts, .stp]')"
ck "the VLANs on a port"                            '{"mode":"trunk","tagged":[200]}' "$(deep '.objects[] | select(.class == "port" and .name == "1") | .attributes.vlans')"
ck "the MAC seen behind a port, lowercased"         '"aa:bb:cc:dd:ee:01"' "$(deep '.objects[] | select(.class == "port" and .name == "10") | .attributes.seen[0].mac')"
ck "the LLDP neighbour"                             '"Core"' "$(deep '.objects[] | select(.class == "port" and .name == "ether1") | .attributes.seen[0].lldp.name')"
ck "an undeclared VLAN, the switch's and a port's"  '[{"tag":410,"declared":false},{"tag":999,"name":"forgotten","declared":false}]' \
   "$(deep '.objects[] | select(.class == "device" and .name == "core") | .attributes.vlans | map(select(.declared | not))')"
ck "a declared VLAN says so"                        'true' "$(deep '.objects[] | select(.class == "device" and .name == "core") | .attributes.vlans[] | select(.tag == 200) | .declared')"
ck "the switch's address, firmware and uptime"      '["10.0.0.201","7.1.66",864000]' "$(deep '.objects[] | select(.class == "device" and .name == "core") | .attributes | [.managementAddress, .firmware, .uptime]')"

# ── lib/cmdb-report.sh: the job id, and each report sent on its own ──
(
    # shellcheck source=../../lib/cmdb-report.sh
    . "${HERE}/../../lib/cmdb-report.sh"
    printf '#!/usr/bin/env bash\n[[ "$1" == report ]] || exit 0\nr="$(cat)"; echo "${r}" >> "%s/lib.jsonl"\n[[ "${r}" == *refuse-me* ]] && exit 4\nexit 0\n' "${TMP}" > "${TMP}/fake-cmdb"
    chmod +x "${TMP}/fake-cmdb"
    export CMDB_BIN="${TMP}/fake-cmdb" TAPPAAS_CMDB=
    ck "cmdb_change_head: the verb, the console's job, the actor" '{"kind":"change","verb":"v","job":"job-9","actor":"op"}' \
       "$(TAPPAAS_JOB_ID=job-9 TAPPAAS_ACTOR=op cmdb_change_head v)"
    jq -cn '[{source:"t", objects:[{class:"zone", name:"refuse-me"}]}, {source:"t", objects:[], relations:[]}, {source:"t", objects:[{class:"zone", name:"b"}]}]' \
        | cmdb_send_reports 2>/dev/null
    ck "cmdb_send_reports: a refused report does not stop the next; empty ones are not sent" '2' "$(wc -l < "${TMP}/lib.jsonl" | tr -d ' ')"
    echo '[{"source":"t","objects":[{"class":"zone","name":"c"}]}]' | TAPPAAS_CMDB=off cmdb_send_reports
    ck "TAPPAAS_CMDB=off sends nothing" '2' "$(wc -l < "${TMP}/lib.jsonl" | tr -d ' ')"
    echo "${PASS} ${FAIL}" > "${TMP}/sub.counts"
)
read -r PASS FAIL < "${TMP}/sub.counts"

# ── the CLI (where switch-manager runs) ──
if [[ -r /home/tappaas/bin/common-install-routines.sh ]]; then
    export CONFIG_DIR="${TMP}"
    cp "${FX}/actual.json" "${TMP}/switch-configuration-actual.json"
    cp "${FX}/positions.json" "${TMP}/positions.json"
    echo '{"mgmt": {"state": "Manual", "vlantag": 0}, "srv": {"state": "Active", "vlantag": 200}}' > "${TMP}/zones.json"
    printf '#!/usr/bin/env bash\n[[ "$1" == report ]] && cat >> "%s/sent.jsonl" && echo >> "%s/sent.jsonl"\nexit 0\n' "${TMP}" "${TMP}" > "${TMP}/cmdb"
    chmod +x "${TMP}/cmdb"
    export CMDB_BIN="${TMP}/cmdb" TAPPAAS_JOB_ID=job-42 TAPPAAS_CMDB=
    SENT="$("${HERE}/switch-manager" report --json 2>/dev/null)"
    ck "report --json prints what the filter builds" "$(jq -c . <<<"${R}")" \
       "$(jq -c 'walk(if type == "object" then del(.assignment, .lags) else . end)' <<<"${SENT}")"
    ck "…with each port's list-ports row, on its switch" '["node","tappaas1","in-sync","core"]' \
       "$(jq -c '.[0].objects[] | select(.ref == "port:sw-01/1") | .attributes.assignment | [.type, .target, .drift, .switch]' <<<"${SENT}")"
    ck "…and each switch's LAGs" '["bond0","lag-t1"]' "$(jq -c '[.[0].objects[] | select(.ref == "device:core") | .attributes.lags[].name]' <<<"${SENT}")"
    "${HERE}/switch-manager" modify-switch core --description "rack top" >/dev/null 2>&1
    ck "modify-switch reports a change with the console's job id" '"job-42"' "$(jq -sc 'map(select(.kind == "change")) | .[0].job' "${TMP}/sent.jsonl" 2>/dev/null)"
else
    echo "  SKIP: the CLI checks (switch-manager runs on tappaas-cicd only)"
fi

echo ""
echo "test-cmdb-report: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
