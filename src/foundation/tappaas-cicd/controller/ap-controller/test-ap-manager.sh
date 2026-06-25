#!/usr/bin/env bash
#
# Unit tests for ap-manager — the WiFi AP/SSID provider (ADR-008, #339).
#
# Black-box / offline: drives ap-manager (and switch-controller for the uplink
# cross-check) against a temp CONFIG_DIR with a fixture zones.json. No live APs
# (manual plugin fallback). Covers ADR-008 test plan AP-01..AP-04.
#
# Usage: ./test-ap-manager.sh   — exit 0 all passed, 1 otherwise.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AM="${SCRIPT_DIR}/ap-controller"
SM="${SCRIPT_DIR}/switch-controller"

TMP="$(mktemp -d)"
export CONFIG_DIR="${TMP}"
cat > "${TMP}/zones.json" <<'JSON'
{
  "mgmt":  { "state":"Manual","vlantag":0 },
  "home":  { "state":"Active","vlantag":310, "SSID":"TAPPaaS-Home" },
  "guest": { "state":"Active","vlantag":510, "SSID":"TAPPaaS-Guest" },
  "work":  { "state":"Active","vlantag":320, "SSID":"TAPPaaS-Work" }
}
JSON
trap 'rm -rf "${TMP}"' EXIT

DES="${TMP}/switch-configuration-desired.json"
PASS=0; FAIL=0
ck() {
    local desc="$1" exp="$2" got="$3"
    if [[ "${exp}" == "${got}" ]]; then echo "  ok: ${desc}"; PASS=$((PASS+1))
    else echo "  FAIL: ${desc} (expected '${exp}', got '${got}')"; FAIL=$((FAIL+1)); fi
}
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
has() { grep -q "$2" <<< "$1" && echo yes || echo no; }

echo "test-ap-manager:"

# AP-01: add creates AP with required fields
"${AM}" add ap-living --vendor unifi --ip 10.0.0.30 >/dev/null 2>&1
ck "AP-01 add creates AP"            "unifi"  "$(jq -r '.accessPoints["ap-living"].vendor' "${DES}")"
ck "add duplicate rejected (rc)"     "1"      "$(rc_of "${AM}" add ap-living --vendor unifi)"

# AP-02: ssid add validates zone exists; VLAN auto-derived from zone
"${AM}" ssid ap-living add TAPPaaS-Home --zone home --security wpa3-personal >/dev/null 2>&1
ck "AP-02 ssid vlan auto from zone"  "310"    "$(jq -r '.accessPoints["ap-living"].ssids["TAPPaaS-Home"].vlan' "${DES}")"
ck "AP-02 ssid zone recorded"        "home"   "$(jq -r '.accessPoints["ap-living"].ssids["TAPPaaS-Home"].zone' "${DES}")"
ck "ssid add unknown zone rejected (rc)" "1"   "$(rc_of "${AM}" ssid ap-living add Bad --zone nosuch --security open)"

"${AM}" ssid ap-living add TAPPaaS-Guest --zone guest --security wpa3-personal --captive >/dev/null 2>&1
ck "ssid captive flag"               "true"   "$(jq -r '.accessPoints["ap-living"].ssids["TAPPaaS-Guest"].captivePortal' "${DES}")"

# AP-03: link records uplink switch/port
"${AM}" link ap-living --switch core-sw1 --port 12 >/dev/null 2>&1
ck "AP-03 link uplinkSwitch"         "core-sw1" "$(jq -r '.accessPoints["ap-living"].uplinkSwitch' "${DES}")"
ck "AP-03 link uplinkPort"           "12"     "$(jq -r '.accessPoints["ap-living"].uplinkPort' "${DES}")"

# update-desired tracks SSID VLAN when its zone is renumbered
jq '.home.vlantag=311' "${TMP}/zones.json" > "${TMP}/z2" && mv "${TMP}/z2" "${TMP}/zones.json"
"${AM}" update-desired >/dev/null 2>&1
ck "update-desired tracks SSID vlan renumber" "311" "$(jq -r '.accessPoints["ap-living"].ssids["TAPPaaS-Home"].vlan' "${DES}")"
jq '.home.vlantag=310' "${TMP}/zones.json" > "${TMP}/z2" && mv "${TMP}/z2" "${TMP}/zones.json"
"${AM}" update-desired >/dev/null 2>&1

# AP-04: delta detects SSID create + validation: zone work declares SSID 'TAPPaaS-Work' but no AP serves it
delta_out="$("${AM}" delta 2>&1)"
ck "AP-04 create-ssid detected"      "yes"    "$(has "${delta_out}" 'create-ssid')"
ck "AP-04 unserved-SSID warning"     "yes"    "$(has "${delta_out}" "no AP broadcasts it")"
ck "AP-04 uplink-not-carrying warning" "yes"   "$(has "${delta_out}" 'does not carry VLAN')"

# reconcile --apply via manual plugin → needs-manual (rc 2)
ck "reconcile --apply needs-manual (rc)" "2"  "$(rc_of "${AM}" reconcile --apply)"

# Clean in-sync path: a switch carrying the SSID VLANs, AP SSIDs confirmed.
# Add work SSID so the unserved-zone warning clears, and a switch trunk port 12
# carrying 310/510/320 so the uplink validation passes.
"${AM}" ssid ap-living add TAPPaaS-Work --zone work --security wpa2-enterprise --radius radius.mgmt.internal >/dev/null 2>&1
# Switch uplink carrying the SSID VLANs (new switch-controller CLI): an ap-type trunk
# port → update-desired sets its tagged set to the active VLANs (310,320,510),
# which switch-controller writes into the shared desired file ap-manager validates.
"${SM}" add-switch core-sw1 --vendor unifi --managed manual >/dev/null 2>&1
"${SM}" add-port core-sw1 12 --type ap --target ap-living >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
"${AM}" reconcile --apply >/dev/null 2>&1   # creates+confirms SSIDs (manual → confirm via next line)
"${AM}" confirm >/dev/null 2>&1
ck "after confirm + full coverage → in sync (rc)" "0" "$(rc_of "${AM}" reconcile)"

# CLI guards
ck "--help (rc)"                     "0"      "$(rc_of "${AM}" --help)"
ck "unknown command (rc)"            "1"      "$(rc_of "${AM}" bogus)"
ck "ssid on missing AP (rc)"         "1"      "$(rc_of "${AM}" ssid nope list)"

echo ""
echo "test-ap-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
