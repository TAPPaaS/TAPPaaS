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

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
