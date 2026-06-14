#!/usr/bin/env bash
#
# Unit tests for switch-manager — the physical-switch provider (ADR-008, #339).
#
# Black-box / offline: drives switch-manager against a temp CONFIG_DIR with a
# fixture zones.json. No live switches (manual plugin fallback). Covers the
# ADR-008 test plan SW-01..SW-05 plus the reconcile lifecycle.
#
# Usage: ./test-switch-manager.sh   — exit 0 all passed, 1 otherwise.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SM="${SCRIPT_DIR}/switch-manager"

TMP="$(mktemp -d)"
export CONFIG_DIR="${TMP}"
cat > "${TMP}/zones.json" <<'JSON'
{
  "mgmt": { "state": "Manual",    "vlantag": 0,   "bridge": "lan" },
  "srv":  { "state": "Active",    "vlantag": 200, "bridge": "lan" },
  "home": { "state": "Active",    "vlantag": 310, "bridge": "lan" },
  "dmz":  { "state": "Mandatory", "vlantag": 610, "bridge": "lan" },
  "old":  { "state": "Inactive",  "vlantag": 999, "bridge": "lan" }
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

echo "test-switch-manager:"

# SW-01: add creates a switch with required fields
"${SM}" add core-sw1 --vendor unifi --ip 10.0.0.20 --model USW-Pro-48 >/dev/null 2>&1
ck "SW-01 add creates switch"        "unifi"  "$(jq -r '.switches["core-sw1"].vendor' "${DES}")"
ck "SW-01 add records ip"            "10.0.0.20" "$(jq -r '.switches["core-sw1"].managementIp' "${DES}")"

# add duplicate fails
ck "add duplicate rejected (rc)"     "1"      "$(rc_of "${SM}" add core-sw1 --vendor unifi --ip 1.2.3.4)"

# SW-02: trunk port validates taggedVlans is an array
"${SM}" port core-sw1 1 --mode trunk --source zones --connected-to node:tappaas1:nic0:lan >/dev/null 2>&1
ck "SW-02 trunk port mode"           "trunk"  "$(jq -r '.switches["core-sw1"].ports["1"].mode' "${DES}")"
ck "SW-02 connectedTo parsed"        "tappaas1" "$(jq -r '.switches["core-sw1"].ports["1"].connectedTo.target' "${DES}")"
ck "SW-02 connectedTo iface parsed"  "lan"    "$(jq -r '.switches["core-sw1"].ports["1"].connectedTo.interface' "${DES}")"

# SW-03: access port with zone
"${SM}" port core-sw1 10 --mode access --zone home --connected-to device:printer --mac aa:bb:cc:dd:ee:ff >/dev/null 2>&1
ck "SW-03 access port zone"          "home"   "$(jq -r '.switches["core-sw1"].ports["10"].zone' "${DES}")"

# Phase 0: update-desired — trunk gets active set; access tracks zone vlan
"${SM}" update-desired >/dev/null 2>&1
ck "update-desired trunk = active set" "200,310,610" "$(jq -rc '.switches["core-sw1"].ports["1"].taggedVlans | join(",")' "${DES}")"
ck "update-desired access nativeVlan tracks zone" "310" "$(jq -r '.switches["core-sw1"].ports["10"].nativeVlan' "${DES}")"

# SW-04: reconcile detects VLAN/ports needing config (empty actual) → drift rc 2
ck "SW-04 reconcile dry-run drift (rc)" "2" "$(rc_of "${SM}" reconcile)"

# apply via manual plugin → needs-manual rc 2, then confirm makes it converge
ck "reconcile --apply needs-manual (rc)" "2" "$(rc_of "${SM}" reconcile --apply)"
"${SM}" confirm >/dev/null 2>&1
ck "after confirm reconcile in sync (rc)" "0" "$(rc_of "${SM}" reconcile)"

# SW-05: a zone VLAN renumber is detected on BOTH trunk and access ports
jq '.home.vlantag=311' "${TMP}/zones.json" > "${TMP}/z2" && mv "${TMP}/z2" "${TMP}/zones.json"
delta_out="$("${SM}" delta 2>&1)"   # delta runs against current desired/actual; need update-desired first
"${SM}" update-desired >/dev/null 2>&1
delta_out="$("${SM}" delta 2>&1)"
ck "SW-05 trunk change detected" "yes" "$(grep -q 'trunk-vlans' <<< "${delta_out}" && echo yes || echo no)"
ck "SW-05 access-vlan change detected" "yes" "$(grep -q 'access-vlan' <<< "${delta_out}" && echo yes || echo no)"

# remove
"${SM}" remove core-sw1 >/dev/null 2>&1
ck "remove deletes switch"           "0"      "$(jq -r '.switches | length' "${DES}")"

# CLI guards
ck "--help (rc)"                     "0"      "$(rc_of "${SM}" --help)"
ck "unknown command (rc)"            "1"      "$(rc_of "${SM}" bogus)"
ck "show missing switch (rc)"        "1"      "$(rc_of "${SM}" show nope)"

echo ""
echo "test-switch-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
