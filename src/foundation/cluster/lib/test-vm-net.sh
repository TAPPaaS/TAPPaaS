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

# Use the deployed zones.json if available; else a temp fixture.
ZONES="/home/tappaas/config/zones.json"
TMP_ZONES=""
if [[ ! -f "${ZONES}" ]]; then
    TMP_ZONES="$(mktemp)"
    cat > "${TMP_ZONES}" <<'JSON'
{
  "mgmt": { "state": "Manual",   "vlantag": 0,   "bridge": "lan" },
  "srv":  { "state": "Active",   "vlantag": 210, "bridge": "lan" },
  "dmz":  { "state": "Mandatory","vlantag": 610, "bridge": "lan" },
  "old":  { "state": "Inactive", "vlantag": 999, "bridge": "lan" }
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

# zone → tag
ck "zone srv → 210"  "210" "$(vmnet_zone_vlantag srv "${ZONES}")"
ck "zone mgmt → 0"   "0"   "$(vmnet_zone_vlantag mgmt "${ZONES}")"
# undefined / inactive zones fail (return non-zero)
if vmnet_zone_vlantag nope "${ZONES}" >/dev/null 2>&1; then
    ck "undefined zone fails" "nonzero" "zero"
else
    ck "undefined zone fails" "nonzero" "nonzero"
fi

# tag → zone (reverse)
ck "tag 210 → srv"  "srv"  "$(vmnet_zone_for_tag 210 "${ZONES}")"
ck "tag 0 → mgmt"   "mgmt" "$(vmnet_zone_for_tag 0 "${ZONES}")"

# all-active tags + "ALL" sentinel (issue #194). Compare to an independent jq
# computation from the same zones file so it works for any zones.json.
expected_active=$(jq -r '
    [ to_entries[]
      | select((.value.state=="Active" or .value.state=="Mandatory") and ((.value.vlantag//0)>0))
      | .value.vlantag ] | sort | unique | map(tostring) | join(";")' "${ZONES}")
ck "all_active_tags matches zones" "${expected_active}" "$(vmnet_all_active_tags "${ZONES}")"
ck "ALL sentinel → all active"     "${expected_active}" "$(vmnet_resolve_trunks ALL "${ZONES}")"
ck "* sentinel → all active"       "${expected_active}" "$(vmnet_resolve_trunks '*' "${ZONES}")"

# net option string builder
ck "netopts tagged+mac"   "virtio,bridge=lan,macaddr=AA:BB,tag=210" "$(vmnet_build_netopts lan AA:BB 210 '')"
ck "netopts untagged"     "virtio,bridge=lan,macaddr=AA:BB"          "$(vmnet_build_netopts lan AA:BB 0 '')"
ck "netopts no-mac"       "virtio,bridge=lan,tag=210"                "$(vmnet_build_netopts lan '' 210 '')"
ck "netopts trunks"       "virtio,bridge=lan,tag=210,trunks=310;410" "$(vmnet_build_netopts lan '' 210 '310;410')"
ck "netopts queues"       "virtio,bridge=lan,trunks=210;610,queues=4" "$(vmnet_build_netopts lan '' 0 '210;610' 4)"
ck "netopts queues=0 off" "virtio,bridge=lan"                         "$(vmnet_build_netopts lan '' 0 '' 0)"

# live net line parsing
NET="virtio=02:7A:7E:D3:24:D0,bridge=lan,tag=210"
ck "parse bridge"      "lan"               "$(vmnet_parse "${NET}" bridge)"
ck "parse tag"         "210"               "$(vmnet_parse "${NET}" tag)"
ck "parse mac"         "02:7A:7E:D3:24:D0" "$(vmnet_parse "${NET}" mac)"
ck "parse missing tag" ""                  "$(vmnet_parse "virtio=02:7A,bridge=lan" tag)"
ck "parse queues"      "4"                 "$(vmnet_parse 'virtio=02:7A,bridge=lan,trunks=210;610,queues=4' queues)"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
