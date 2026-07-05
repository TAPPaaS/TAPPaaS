#!/usr/bin/env bash
#
# Unit tests for the reconcile loop in pbs-client.sh (ADR-012 P3, #382).
# The per-node ssh install (_pbs_client_install_one) and cluster enumeration
# (pbs_cluster_nodes) are stubbed, so this exercises the loop + rc semantics:
# every current node is visited, and one node's failure warns without aborting
# the sweep (rc becomes 1 but the remaining nodes are still reconciled).
#
# Usage: ./test-pbs-client.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BL=""; GN=""
# shellcheck disable=SC2034  # read by the sourced libs
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }
get_all_node_hostnames() { printf 'tappaas1\ntappaas2\n'; }

# shellcheck source=pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-placement.sh"
# shellcheck source=pbs-client.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-client.sh"

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# Stub live membership (three nodes) — this is what a grown cluster looks like.
pbs_cluster_nodes() { printf 'tappaas1\ntappaas2\ntappaas3\n'; }

# ── all nodes reconciled, all succeed ────────────────────────────────
CALLS=""
_pbs_client_install_one() { CALLS+="$1 "; return 0; }
pbs_client_reconcile mgmt "http://example/pbs" >/dev/null; r=$?
ck    "reconcile visits every current node" "tappaas1 tappaas2 tappaas3 " "${CALLS}"
ck_rc "reconcile rc 0 when all succeed"     0 "$r"

# ── one node fails: sweep continues, rc becomes 1 ────────────────────
CALLS=""
_pbs_client_install_one() { CALLS+="$1 "; [[ "$1" == "tappaas2" ]] && return 1; return 0; }
pbs_client_reconcile mgmt "http://example/pbs" >/dev/null; r=$?
ck    "reconcile continues past a failing node" "tappaas1 tappaas2 tappaas3 " "${CALLS}"
ck_rc "reconcile rc 1 when a node fails"        1 "$r"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
