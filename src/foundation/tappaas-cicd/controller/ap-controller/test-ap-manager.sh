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
# switch-controller lives in its OWN component dir, not next to ap-controller.
# This pointed at ${SCRIPT_DIR}/switch-controller, which does not exist — so every
# ${SM} call below was a silent no-op (they are all `>/dev/null 2>&1`), the uplink
# switch port was never created, the uplink validation never cleared, and the
# final "in sync" assertion failed. That is the whole of tracker D3
# (`test-ap-manager` 16/1, "not triaged yet"). Fail loudly if it moves again.
SM="${SCRIPT_DIR}/../switch-controller/switch-controller"
[[ -x "${SM}" ]] || { echo "FATAL: switch-controller not found at ${SM}" >&2; exit 1; }

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

# #644: --help in any position runs nothing; an option the verb lacks is refused
before="$(md5sum < "${DES}")"
ck "remove <ap> --help (rc)"         "0"      "$(rc_of "${AM}" remove ap-living --help)"
ck "ssid <ap> remove <ssid> -h (rc)" "0"      "$(rc_of "${AM}" ssid ap-living remove TAPPaaS-Home -h)"
ck "reconcile --apply --help (rc)"   "0"      "$(rc_of "${AM}" reconcile --apply --help)"
ck "…and nothing changed"            "${before}" "$(md5sum < "${DES}")"
ck "remove --help prints remove's usage" "yes" "$(has "$("${AM}" remove x --help)" 'remove <name>')"
ck "reconcile --aply refused (rc)"   "1"      "$(rc_of "${AM}" reconcile --aply)"
ck "remove <ap> --force refused (rc)" "1"     "$(rc_of "${AM}" remove ap-living --force)"
ck "…and nothing changed"            "${before}" "$(md5sum < "${DES}")"
ck "--help works without zones.json" "0"      "$(CONFIG_DIR=/nonexistent rc_of "${AM}" apply --help)"

# ── #733: an AP that cannot be read is reported, never merged or swallowed ──
ACT="${TMP}/switch-configuration-actual.json"
STUB="${TMP}/plugins"; mkdir -p "${STUB}"
cp "/home/tappaas/TAPPaaS/src/foundation/network/scripts/plugins/manual.sh" "${STUB}/"
stub() { printf 'plugin_supports() { [[ "$1" == "stub" ]]; }\nplugin_ap_interrogate() { %s; }\n' "$1" > "${STUB}/stub.sh"; }
stub "echo '{}'"
PLUGIN_DIR="${STUB}" "${AM}" add ap-stub --vendor stub --ip 10.0.0.30 >/dev/null 2>&1
# The old failure: a warning on STDOUT ahead of the JSON. It used to crash the
# merge ('jq: invalid JSON text passed to --argjson') and still exit 0.
stub "echo '[Warning] something'; echo '{\"model\":\"U7\"}'"
before="$(md5sum < "${ACT}")"
out="$(PLUGIN_DIR="${STUB}" "${AM}" interrogate 2>&1)"; rc=$?
ck "#733 polluted answer fails interrogate (rc)" "1" "${rc}"
ck "#733 …no jq crash"                "no"  "$(has "${out}" 'invalid JSON text')"
ck "#733 …names the AP"                "yes" "$(has "${out}" 'ap-stub: not interrogated')"
ck "#733 …actual untouched"            "${before}" "$(md5sum < "${ACT}")"
stub "echo 'UniFi login failed: HTTP 401 — check the LOCAL admin' >&2; echo '{}'; return 1"
out="$(PLUGIN_DIR="${STUB}" "${AM}" interrogate 2>&1)"
ck "#733 the plugin's reason is shown" "yes" "$(has "${out}" 'HTTP 401 — check the LOCAL admin')"
ck "#733 reconcile --apply on stale actual (rc)" "1" "$(PLUGIN_DIR="${STUB}" rc_of "${AM}" reconcile --apply)"
ck "#733 …applies nothing"             "${before}" "$(md5sum < "${ACT}")"
stub "[[ -d \"\${UNIFI_SESSION:-}\" ]] || return 1; echo '{\"model\":\"U7\"}'"
ck "#733 a good answer is merged (rc)" "0"   "$(PLUGIN_DIR="${STUB}" rc_of "${AM}" interrogate)"
ck "#733 …into actual"                 "U7"  "$(jq -r '.accessPoints["ap-stub"].model' "${ACT}")"
PLUGIN_DIR="${STUB}" "${AM}" remove ap-stub >/dev/null 2>&1

# An AP name with a space is ONE AP: delta used to word-split "Nano HD" into two
# APs that exist nowhere, each "in sync", hiding the real AP's changes.
"${AM}" add "Nano HD" --vendor manual --ip 10.0.0.31 >/dev/null 2>&1
"${AM}" ssid "Nano HD" add TAPPaaS-Home --zone home --security wpa2-personal >/dev/null 2>&1
out="$("${AM}" delta 2>&1)"
ck "spaced AP: its change is shown"     "yes" "$(has "${out}" 'Nano HD: 1 change(s)')"
ck "…not split into 'Nano' and 'HD'"    "no"  "$(has "${out}" 'Nano: SSIDs in sync')"
out="$("${AM}" apply 2>&1)"
ck "spaced AP: apply reaches its plugin" "yes" "$(has "${out}" 'Nano HD')"
"${AM}" remove "Nano HD" >/dev/null 2>&1

echo ""
echo "test-ap-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
