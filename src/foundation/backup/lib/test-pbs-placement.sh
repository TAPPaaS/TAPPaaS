#!/usr/bin/env bash
#
# Unit tests for the pure helpers in pbs-placement.sh (ADR-012 §2.1/§2.2).
# No cluster access: state parsing/reading, tankc selection, exact-storage
# probing, node-list parsing, the full state-resolution matrix (with the two
# ssh probes stubbed), and placement-state write/read.
#
# Migration (§4.1) has its own suite: test-pbs-migrate.sh.
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

# ── pbs_state_node ───────────────────────────────────────────────────
ck "state_node: node:tappaas2 → tappaas2" "tappaas2" "$(pbs_state_node 'node:tappaas2')"
pbs_state_node 'shim'     && r=0 || r=1; ck_rc "state_node: shim is not a node"     1 "$r"
pbs_state_node 'external' && r=0 || r=1; ck_rc "state_node: external is not a node" 1 "$r"
pbs_state_node 'node:'    && r=0 || r=1; ck_rc "state_node: empty name rejected"    1 "$r"
pbs_state_node ''         && r=0 || r=1; ck_rc "state_node: empty state rejected"   1 "$r"

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

# ── _pbs_storage_active (exact name, for the legacy-node probe) ──────
_pbs_storage_active "$PVESM" tankc1 && r=0 || r=1; ck_rc "storage_active: exact match"     0 "$r"
_pbs_storage_active "$PVESM" tankc  && r=0 || r=1; ck_rc "storage_active: no prefix match" 1 "$r"
_pbs_storage_active "$PVESM_INACTIVE" tankc1 && r=0 || r=1; ck_rc "storage_active: inactive is not active" 1 "$r"

# ── pbs_storage_probe_state (#636: a busy PBS is not a broken one) ───
HDR='Name     Type  Status   Total  Used  Available  %'
ck "probe: active"   active   "$(pbs_storage_probe_state "$HDR
backup   pbs   active   100    10    90         10" 0 backup)"
ck "probe: 500 read timeout during vzdump → unknown" unknown "$(pbs_storage_probe_state "backup: error fetching datastores - 500 read timeout
$HDR
backup   pbs   inactive 0      0     0          0" 0 backup)"
ck "probe: 500 Can't connect → unknown" unknown "$(pbs_storage_probe_state "backup: error fetching datastores - 500 Can't connect to 10.0.0.5:8007
$HDR
backup   pbs   inactive 0      0     0          0" 0 backup)"
ck "probe: pvesm timed out → unknown"   unknown "$(pbs_storage_probe_state "" 124 backup)"
ck "probe: ssh failed → unknown"        unknown "$(pbs_storage_probe_state "" 255 backup)"
ck "probe: empty output → unknown"      unknown "$(pbs_storage_probe_state "" 0 backup)"
ck "probe: not configured → missing"    missing "$(pbs_storage_probe_state "storage 'backup' does not exist" 2 backup)"
ck "probe: clean inactive → inactive"   inactive "$(pbs_storage_probe_state "$HDR
backup   pbs   inactive 0      0     0          0" 0 backup)"
ck "probe: another storage's error is not ours" inactive "$(pbs_storage_probe_state "$HDR
backup   pbs   inactive 0      0     0          0
backupx  pbs   active   1      1     1          1" 0 backup)"

# ── _pbs_nodes_from_json ─────────────────────────────────────────────
ck "nodes from json" $'tappaas1\ntappaas2' "$(_pbs_nodes_from_json '[{"node":"tappaas1"},{"node":"tappaas2"}]')"
ck "nodes from empty" "" "$(_pbs_nodes_from_json '[]')"

# ── state + pbsUrl readers ───────────────────────────────────────────
TMP="$(mktemp -d)"
echo '{}'                              > "${TMP}/backup.json"
ck "state: absent → empty"       ""                      "$(pbs_placement_state "${TMP}/backup.json")"
ck "pbsUrl: default"             "backup.mgmt.internal"  "$(pbs_pbs_url        "${TMP}/backup.json")"
echo '{"pbsUrl":""}'                   > "${TMP}/backup.json"
ck "pbsUrl: empty → default"     "backup.mgmt.internal"  "$(pbs_pbs_url        "${TMP}/backup.json")"
echo '{"pbsUrl":"pbs.example.org"}'    > "${TMP}/backup.json"
ck "pbsUrl: explicit"            "pbs.example.org"       "$(pbs_pbs_url        "${TMP}/backup.json")"
echo '{"placementState":"node:tappaas3"}' > "${TMP}/backup.json"
ck "state: node:<name> read"     "node:tappaas3"         "$(pbs_placement_state "${TMP}/backup.json")"

# ── pbs_resolve_placement_state (probes stubbed) ─────────────────────
# Stub the two ssh-backed probes: STUB_TANKC maps node → storage ("" = none).
declare -A STUB_TANKC=()
pbs_probe_tankc()   { printf '%s\n' "${STUB_TANKC[$1]:-}"; }
pbs_cluster_nodes() { printf 'tappaas1\ntappaas2\ntappaas3\n'; }

ck "resolve: external is sticky"   "external" "$(pbs_resolve_placement_state external '' mgmt)"
ck "resolve: external ignores a node constraint" \
                                   "external" "$(pbs_resolve_placement_state external tappaas2 mgmt)"

STUB_TANKC=([tappaas3]=tankc1)
ck "resolve: node:<name> kept + storage re-probed" \
   "node:tappaas3 tankc1" "$(pbs_resolve_placement_state 'node:tappaas3' '' mgmt)"
ck "resolve: empty + no constraint → first node with a tankc" \
   "node:tappaas3 tankc1" "$(pbs_resolve_placement_state '' '' mgmt)"
ck "resolve: shim + no constraint → promotes when a tankc appears" \
   "node:tappaas3 tankc1" "$(pbs_resolve_placement_state shim '' mgmt)"
ck "resolve: constraint restricts discovery to that node (none there → shim)" \
   "shim" "$(pbs_resolve_placement_state '' tappaas2 mgmt)"
ck "resolve: constraint honoured when it does have a tankc" \
   "node:tappaas3 tankc1" "$(pbs_resolve_placement_state '' tappaas3 mgmt)"

STUB_TANKC=([tappaas2]=tankc2 [tappaas3]=tankc1)
ck "resolve: no constraint → first node in cluster order wins" \
   "node:tappaas2 tankc2" "$(pbs_resolve_placement_state '' '' mgmt)"

STUB_TANKC=()
ck "resolve: nothing anywhere → shim"        "shim" "$(pbs_resolve_placement_state ''    '' mgmt)"
ck "resolve: shim stays shim without storage" "shim" "$(pbs_resolve_placement_state shim '' mgmt)"
ck "resolve: node:<name> kept even with no storage (storage empty)" \
   "node:tappaas3" "$(pbs_resolve_placement_state 'node:tappaas3' '' mgmt)"

# ── placement-state write/read roundtrip + predicates ────────────────
PBS_PLACEMENT_CONFIG_DIR="${TMP}"
echo '{"vmname":"backup","node":"tappaas9"}' > "${TMP}/backup.json"
pbs_write_placement_state 'node:tappaas2' tankc1
ck "write: state recorded"    "node:tappaas2" "$(pbs_placement_state)"
ck "write: storage recorded"  "tankc1"        "$(jq -r '.storage' "${TMP}/backup.json")"
ck "write: .node (the operator's discovery constraint) is NOT overwritten" \
                              "tappaas9"      "$(jq -r '.node'    "${TMP}/backup.json")"
pbs_is_shim     && r=0 || r=1; ck_rc "predicate: not shim when node:"     1 "$r"
pbs_is_external && r=0 || r=1; ck_rc "predicate: not external when node:" 1 "$r"
pbs_is_local    && r=0 || r=1; ck_rc "predicate: is local when node:"     0 "$r"

pbs_write_placement_state shim
ck "write: shim recorded" "shim" "$(pbs_placement_state)"
ck "write: storage kept when not passed" "tankc1" "$(jq -r '.storage' "${TMP}/backup.json")"
pbs_is_shim     && r=0 || r=1; ck_rc "predicate: is shim when shim"     0 "$r"
pbs_is_local    && r=0 || r=1; ck_rc "predicate: not local when shim"   1 "$r"

pbs_write_placement_state external
ck "write: external recorded" "external" "$(pbs_placement_state)"
pbs_is_external && r=0 || r=1; ck_rc "predicate: is external when external" 0 "$r"
pbs_is_shim     && r=0 || r=1; ck_rc "predicate: not shim when external"    1 "$r"
pbs_is_local    && r=0 || r=1; ck_rc "predicate: not local when external"   1 "$r"

rm -rf "${TMP}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
