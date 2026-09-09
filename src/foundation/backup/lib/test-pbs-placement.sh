#!/usr/bin/env bash
#
# Unit tests for the pure helpers in pbs-placement.sh (ADR-012 P1/P2).
# No cluster access — placement policy parsing, tankc selection, node parsing,
# the shim/remote-only discovery branches, and placement-state read/write.
#
# Usage: ./test-pbs-placement.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging + colour + node stubs so the lib sources standalone.
info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BGN=""; BL=""; GN=""
# shellcheck disable=SC2034  # read by the sourced lib (PBS_PLACEMENT_CONFIG_DIR)
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }
get_all_node_hostnames() { printf 'tappaas1\ntappaas2\n'; }

# shellcheck source=pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-placement.sh"

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── _placement_node_pin ──────────────────────────────────────────────
ck "pin: node:tappaas2 → tappaas2" "tappaas2" "$(_placement_node_pin 'node:tappaas2')"
_placement_node_pin 'auto'  && r=0 || r=1; ck_rc "pin: auto is not a pin"       1 "$r"
_placement_node_pin 'node:' && r=0 || r=1; ck_rc "pin: empty name rejected"     1 "$r"

# ── _tankc_pick (first ACTIVE tankc*) ────────────────────────────────
PVESM='Name             Type      Status     Total    Used    Avail   %
local            dir       active     100      10      90      10
tankc1           zfspool   active     200      20      180     10
tanka1           zfspool   active     300      30      270     10'
ck "tankc_pick: first active tankc"   "tankc1" "$(_tankc_pick "$PVESM")"
ck "tankc_pick: prefix arg (tanka)"   "tanka1" "$(_tankc_pick "$PVESM" tanka)"

PVESM_INACTIVE='Name    Type      Status
tankc1  zfspool   inactive
tankc2  zfspool   active'
ck "tankc_pick: skips inactive"       "tankc2" "$(_tankc_pick "$PVESM_INACTIVE")"

ck "tankc_pick: none present"         ""       "$(_tankc_pick 'Name  Type  Status
local dir   active')"

# ── _pbs_nodes_from_json ─────────────────────────────────────────────
ck "nodes from json" $'tappaas1\ntappaas2' "$(_pbs_nodes_from_json '[{"node":"tappaas1"},{"node":"tappaas2"}]')"
ck "nodes from empty" "" "$(_pbs_nodes_from_json '[]')"

# ── placement_policy (default + explicit) ────────────────────────────
TMP="$(mktemp -d)"
echo '{}'                     > "${TMP}/backup.json"; ck "policy: default auto"  "auto" "$(placement_policy "${TMP}/backup.json")"
echo '{"placement":"shim"}'   > "${TMP}/backup.json"; ck "policy: explicit shim" "shim" "$(placement_policy "${TMP}/backup.json")"
echo '{"placement":"node:x"}' > "${TMP}/backup.json"; ck "policy: node pin"      "node:x" "$(placement_policy "${TMP}/backup.json")"

# ── pbs_discover_placement: ssh-free branches ────────────────────────
ck "discover: shim policy"         "shim"        "$(pbs_discover_placement shim        tappaas1 mgmt)"
ck "discover: remote-only policy"  "remote-only" "$(pbs_discover_placement remote-only tappaas1 mgmt)"

# ── placement-state write/read roundtrip ─────────────────────────────
PBS_PLACEMENT_CONFIG_DIR="${TMP}"
echo '{"vmname":"backup"}' > "${TMP}/backup.json"
pbs_write_placement_state local tappaas2 tankc1
ck "state: local written"   "local"    "$(pbs_placement_state)"
ck "state: node written"    "tappaas2" "$(jq -r '.node'    "${TMP}/backup.json")"
ck "state: storage written" "tankc1"   "$(jq -r '.storage' "${TMP}/backup.json")"
pbs_is_shim && r=0 || r=1; ck_rc "state: not shim when local" 1 "$r"

pbs_write_placement_state shim
ck "state: shim written"    "shim"     "$(pbs_placement_state)"
pbs_is_shim && r=0 || r=1; ck_rc "state: is shim when shim"   0 "$r"

rm -rf "${TMP}"

# ── probe: a PBS host outside the cluster is discovered, not skipped (#601) ──
# `pvesm` is a Proxmox VE command. A Site-managed PBS host that is not a cluster
# member has no Proxmox storage layer at all, so the PVE probe can never succeed
# on it; without the native fallback the host is invisible to discovery and
# resolution walks off to a cluster member instead.
ssh() {
    local host="" cmd=""
    while [[ $# -gt 0 ]]; do
        case "$1" in root@*) host="$1" ;; esac
        cmd="$1"; shift
    done
    case "${host}" in
        root@pvehost.mgmt.internal)
            [[ "${cmd}" == *"pvesm status"* ]] && { printf '%s\n' "${PVESM}"; return 0; }
            return 127 ;;
        root@barepbs.mgmt.internal)                      # PBS on bare metal, no pvesm
            [[ "${cmd}" == *"pvesm status"* ]]            && return 127
            [[ "${cmd}" == *proxmox-backup-manager* ]]    && { echo "tankc1"; return 0; }
            return 1 ;;
        root@nopbs.mgmt.internal)                        # reachable, but not a PBS host
            return 127 ;;
        root@down.mgmt.internal) return 255 ;;           # ssh itself fails
    esac
    return 1
}

ck "probe: pve host via pvesm"          "tankc1" "$(pbs_probe_tankc pvehost mgmt)"
ck "probe: non-pve PBS host natively"   "tankc1" "$(pbs_probe_tankc barepbs mgmt)"
ck "probe: reachable non-PBS host"      ""       "$(pbs_probe_tankc nopbs   mgmt)"
ck "probe: unreachable host"            ""       "$(pbs_probe_tankc down    mgmt)"

# Acceptance test for the topology (ADR-012 §1.2): a configured host that is not
# a cluster member and serves PBS resolves to that host — not to a cluster member,
# and not to a shim.
get_all_node_hostnames() { printf 'tappaas1\ntappaas2\n'; }
ck "discover: non-member configured host wins" \
   "local barepbs tankc1" "$(pbs_discover_placement auto barepbs mgmt)"
ck "discover: no pool anywhere → shim" \
   "shim" "$(pbs_discover_placement auto nopbs mgmt)"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
