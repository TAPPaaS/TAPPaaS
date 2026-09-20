#!/usr/bin/env bash
#
# test-node-mgmt-ip.sh — unit test for config-network.sh's node_mgmt_ip (#673).
#
# The node number is a SEQUENCE: tappaasN gets <subnet>.<9+N> for any N, and the
# addresses run out where the mgmt DHCP pool begins — not at a fixed count of
# nodes. The function is lifted out of config-network.sh (which otherwise runs on
# the node itself, from a live console) with `hostname` and `die` stubbed, so the
# rule is tested without a node.
#
# Usage: ./test-node-mgmt-ip.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../config-network.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

# The function under test, with the script's two constants and its collaborators.
FN="$(sed -n '/^node_mgmt_ip() {/,/^}/p' "${SRC}")"
[[ -n "${FN}" ]] || { echo "FAIL: node_mgmt_ip not found in ${SRC}"; exit 1; }

ip_for() {   # ip_for <hostname> [mgmt-ip-override]
    bash -c '
        readonly MGMT_SUBNET="10.0.0"
        readonly MGMT_POOL_START=100
        MGMT_IP="$2"
        _FAKE_HOST="$1"
        hostname() { echo "${_FAKE_HOST}"; }   # the stub ignores -s
        die() { echo "DIE: $*" >&2; exit 1; }
        '"${FN}"'
        node_mgmt_ip
    ' _ "$1" "${2:-}" 2>&1
}

ck "tappaas1 → .10"                 "10.0.0.10" "$(ip_for tappaas1)"
ck "tappaas2 → .11"                 "10.0.0.11" "$(ip_for tappaas2)"
ck "tappaas9 → .18"                 "10.0.0.18" "$(ip_for tappaas9)"
ck "tappaas10 → .19 (was refused)"  "10.0.0.19" "$(ip_for tappaas10)"
ck "tappaas42 → .51"                "10.0.0.51" "$(ip_for tappaas42)"
ck "tappaas90 → .99, the last one"  "10.0.0.99" "$(ip_for tappaas90)"

out="$(ip_for tappaas91)"
[[ "${out}" == DIE:* && "${out}" == *"DHCP pool"* ]] \
    && ck "tappaas91 would hit the pool → refused, and says why" ok ok \
    || ck "tappaas91 refused" ok "got: ${out}"

ck "a name with no number → .10"    "10.0.0.10" "$(ip_for pve)"
ck "--mgmt-ip wins, CIDR stripped"  "10.0.0.250" "$(ip_for tappaas3 10.0.0.250/24)"

echo ""
echo "node-mgmt-ip: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
