#!/usr/bin/env bash
#
# Unit tests for vm-net.sh — the zone/VLAN/net-string helpers used by the
# cluster:vm update-service reconciler (issue #192).
#
# Pure-function tests: no Proxmox/cluster access. Uses the live zones.json if
# present, otherwise a bundled fixture, so it runs anywhere.
#
# Usage: ./test-vm-net.sh
# Exit: 0 all passed, 1 otherwise.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Minimal logging stubs so the lib can be sourced standalone.
info() { :; }
debug() { :; }
warn() { echo "WARN: $*" >&2; }
error() { echo "ERR: $*" >&2; }

# shellcheck source=vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/vm-net.sh"

# Prefer the source-tree zones.json (canonical, always in-tree with this test).
# Falls back to the deployed config, then a bundled fixture. This decouples the
# unit test from the live operator state (#237).
ZONES_REPO_SRC="$(cd "${SCRIPT_DIR}/../.." && pwd)/firewall/zones.json"
ZONES_DEPLOYED="/home/tappaas/config/zones.json"
TMP_ZONES=""
if [[ -f "${ZONES_REPO_SRC}" ]]; then
    ZONES="${ZONES_REPO_SRC}"
elif [[ -f "${ZONES_DEPLOYED}" ]]; then
    ZONES="${ZONES_DEPLOYED}"
else
    TMP_ZONES="$(mktemp)"
    cat > "${TMP_ZONES}" <<'JSON'
{
  "mgmt":     { "state": "Manual",   "vlantag": 0,   "bridge": "lan" },
  "srvHome": { "state": "Active",   "vlantag": 210, "bridge": "lan" },
  "dmz":      { "state": "Mandatory","vlantag": 610, "bridge": "lan" },
  "old":      { "state": "Inactive", "vlantag": 999, "bridge": "lan" }
}
JSON
    ZONES="${TMP_ZONES}"
fi
trap '[[ -n "${TMP_ZONES}" ]] && rm -f "${TMP_ZONES}"' EXIT

PASS=0
FAIL=0
ck() {
    local desc="$1" exp="$2" got="$3"
    if [[ "${exp}" == "${got}" ]]; then
        echo "  ok: ${desc}"; PASS=$((PASS + 1))
    else
        echo "  FAIL: ${desc} (expected '${exp}', got '${got}')"; FAIL=$((FAIL + 1))
    fi
}

# zone → tag (srvHome is the Active 210 zone post-#178)
ck "zone srvHome → 210"  "210" "$(vmnet_zone_vlantag srvHome "${ZONES}")"
ck "zone mgmt → 0"        "0"   "$(vmnet_zone_vlantag mgmt "${ZONES}")"
# undefined / inactive zones fail (return non-zero)
if vmnet_zone_vlantag nope "${ZONES}" >/dev/null 2>&1; then
    ck "undefined zone fails" "nonzero" "zero"
else
    ck "undefined zone fails" "nonzero" "nonzero"
fi

# tag → zone (reverse)
ck "tag 210 → srvHome"  "srvHome"  "$(vmnet_zone_for_tag 210 "${ZONES}")"
ck "tag 0 → mgmt"        "mgmt"      "$(vmnet_zone_for_tag 0 "${ZONES}")"

# all-active tags + "ALL" sentinel (issue #194). Compare to an independent jq
# computation from the same zones file so it works for any zones.json.
expected_active=$(jq -r '
    [ to_entries[]
      | select((.value.state=="Active" or .value.state=="Mandatory") and ((.value.vlantag//0)>0))
      | .value.vlantag ] | sort | unique | map(tostring) | join(";")' "${ZONES}")
ck "all_active_tags matches zones" "${expected_active}" "$(vmnet_all_active_tags "${ZONES}")"
ck "ALL sentinel → all active"     "${expected_active}" "$(vmnet_resolve_trunks ALL "${ZONES}")"
ck "* sentinel → all active"       "${expected_active}" "$(vmnet_resolve_trunks '*' "${ZONES}")"

# net option string builder — MAC carried inline as virtio=<MAC> (issue #204)
ck "netopts tagged+mac"   "virtio=AA:BB,bridge=lan,tag=210"          "$(vmnet_build_netopts lan AA:BB 210 '')"
ck "netopts untagged"     "virtio=AA:BB,bridge=lan"                  "$(vmnet_build_netopts lan AA:BB 0 '')"
ck "netopts no-mac"       "virtio,bridge=lan,tag=210"                "$(vmnet_build_netopts lan '' 210 '')"
ck "netopts trunks"       "virtio,bridge=lan,tag=210,trunks=310;410" "$(vmnet_build_netopts lan '' 210 '310;410')"
ck "netopts queues"       "virtio,bridge=lan,trunks=210;610,queues=4" "$(vmnet_build_netopts lan '' 0 '210;610' 4)"
ck "netopts queues=0 off" "virtio,bridge=lan"                         "$(vmnet_build_netopts lan '' 0 '' 0)"

# ── #211: explicit-list state allowlist + vlantag=0 guard ────────────
# vmnet_resolve_trunks must skip Inactive *and* Disabled zones, and reject
# vlantag=0 (untagged) entries — the ALL sentinel already does this, but the
# explicit-list path previously only skipped Inactive. We need a deterministic
# fixture for these assertions (the live zones.json content varies).

EXPLICIT_FIXTURE="$(mktemp)"
cat > "${EXPLICIT_FIXTURE}" <<'JSON'
{
  "mgmt":     { "state": "Manual",    "vlantag": 0,   "bridge": "lan" },
  "srv":      { "state": "Active",    "vlantag": 200, "bridge": "lan" },
  "srvHome": { "state": "Active",    "vlantag": 210, "bridge": "lan" },
  "dmz":      { "state": "Mandatory", "vlantag": 610, "bridge": "lan" },
  "manual-z": { "state": "Manual",    "vlantag": 700, "bridge": "lan" },
  "iot-off":  { "state": "Disabled",  "vlantag": 440, "bridge": "lan" },
  "old":      { "state": "Inactive",  "vlantag": 999, "bridge": "lan" }
}
JSON

# Active and Mandatory included as before.
ck "#211 explicit: Active+Mandatory" "200;610" \
    "$(vmnet_resolve_trunks 'srv;dmz' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

# Manual zone with a real vlantag is included on an explicit list (operator
# intent — they typed it). ALL sentinel still excludes Manual; that asymmetry
# is intentional per the issue resolution.
ck "#211 explicit: Manual trunkable" "200;700" \
    "$(vmnet_resolve_trunks 'srv;manual-z' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

# Disabled is skipped (the original bug — previously included).
ck "#211 explicit: Disabled skipped" "200;610" \
    "$(vmnet_resolve_trunks 'srv;iot-off;dmz' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

# Inactive is still skipped (pre-existing behavior preserved).
ck "#211 explicit: Inactive skipped" "200;610" \
    "$(vmnet_resolve_trunks 'srv;old;dmz' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

# vlantag=0 (Manual mgmt) is skipped — untagged is meaningless on a trunk.
ck "#211 explicit: vlantag=0 skipped" "200" \
    "$(vmnet_resolve_trunks 'mgmt;srv' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

# A list that is ALL bad → empty result, no error.
ck "#211 explicit: all-bad → empty" "" \
    "$(vmnet_resolve_trunks 'mgmt;iot-off;old' "${EXPLICIT_FIXTURE}" 2>/dev/null)"

rm -f "${EXPLICIT_FIXTURE}"

# live net line parsing
NET="virtio=02:7A:7E:D3:24:D0,bridge=lan,tag=210"
ck "parse bridge"      "lan"               "$(vmnet_parse "${NET}" bridge)"
ck "parse tag"         "210"               "$(vmnet_parse "${NET}" tag)"
ck "parse mac"         "02:7A:7E:D3:24:D0" "$(vmnet_parse "${NET}" mac)"
ck "parse missing tag" ""                  "$(vmnet_parse "virtio=02:7A,bridge=lan" tag)"
ck "parse queues"      "4"                 "$(vmnet_parse 'virtio=02:7A,bridge=lan,trunks=210;610,queues=4' queues)"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
