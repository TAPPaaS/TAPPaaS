#!/usr/bin/env bash
#
# Regression tests for update.sh's legacy-placement guard (#625).
#
# The guard decides what a legacy `placementState: local` becomes, and it runs
# under update.sh's `set -euo pipefail`. That is the whole point of this file:
# the sibling suites source the helper libs WITHOUT `-e` and call predicates
# inside `$( )`, where an abort cannot happen — so a bare
# `pbs_node_is_cluster_member …; rc=$?` passed every test while killing the
# script on the only two returns the case exists to read.
#
# So: extract the real block out of update.sh and run it in a child `bash -e`
# with stubbed helpers. Anything that re-introduces an untested call fails here.
#
# The contract under test:
#   member (rc 0)     → block completes, the node hint survives → node:<name>
#   non-member (rc 1) → adopt external, clear the hint, keep going
#   unreachable (rc 2)→ exit 0, touch nothing
#   adopt failed      → exit 0, NOT a fall-through to the node:<name> write
#
# Usage: ./test-pbs-legacy-guard.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SH="${SCRIPT_DIR}/../update.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
# yes/no on "the run said this", so the assertions read as the contract
said()  { [[ "${out}" == *"$1"* ]] && echo yes || echo no; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
BLOCK="${TMP}/guard.sh"

# ── extract the guard: `LEGACY_NODE=""` up to the migrate call that reads it ──
awk '/^LEGACY_NODE=""$/ {on=1} /^pbs_migrate_placement_state /{on=0} on' \
    "${UPDATE_SH}" > "${BLOCK}"
if ! grep -q 'pbs_node_is_cluster_member' "${BLOCK}"; then
    echo "  FAIL: could not extract the guard block from update.sh — anchors moved,"
    echo "        so this suite is testing nothing. Fix the awk range above."
    echo "RESULT: 0 passed, 1 failed"
    exit 1
fi

# ── run the extracted block under update.sh's own shell options ──────────────
# member_rc: what the membership predicate returns. adopt_rc: whether recording
# the external placement succeeds. Prints one line naming what the block did.
run_guard() { # run_guard <member_rc> <adopt_rc>
    bash 2>&1 <<SH
set -euo pipefail
ZONE="mgmt"
BOLD=""; CL=""; BL=""; GN=""; BGN=""
info() { :; }; debug() { :; }; error() { echo "ERR: \$*"; }
warn() { echo "warn: \$*"; }
get_config_value() { echo "\${2:-}"; }
. "${SCRIPT_DIR}/pbs-dns.sh"      # the DNS name is the instance's (#612)
INSTANCE="backup"
pbs_placement_state()       { echo "local"; }
pbs_legacy_pbs_node()       { echo "tappaas3"; }
pbs_node_is_cluster_member() { return $1; }
pbs_adopt_external_pbs()    { echo "adopt: \$1"; return $2; }

. "${BLOCK}"

# Only reached if the block did not exit: this stands in for the migrate call
# and everything after it (client reconcile, job reconcile, the retrofits).
echo "continued: LEGACY_NODE=[\${LEGACY_NODE}]"
SH
}

# ── rc 0: a real cluster member — the ordinary node:<name> case ───────────────
out="$(run_guard 0 0)"
ck "member: the block continues"            "yes" "$(said 'continued:')"
ck "member: the node hint survives"         "yes" "$(said 'LEGACY_NODE=[tappaas3]')"
ck "member: nothing is adopted"             "no"  "$(said 'adopt:')"

# ── rc 1: not a member — adopt as external and keep going ────────────────────
# The branch #625 killed: under `set -e` a bare call ended the script here, so
# the adoption, the client reconcile and the retrofits never ran.
out="$(run_guard 1 0)"
ck "non-member: the block continues (#625)" "yes" "$(said 'continued:')"
ck "non-member: adopted by DNS name"        "yes" "$(said 'adopt: backup.mgmt.internal')"
ck "non-member: the node hint is cleared"   "yes" "$(said 'LEGACY_NODE=[]')"
ck "non-member: says why"                   "yes" "$(said 'NOT a member of this cluster')"

# ── rc 2: cluster unreachable — leave the state alone ────────────────────────
out="$(run_guard 2 0)"
ck "unreachable: the block stops"           "no"  "$(said 'continued:')"
ck "unreachable: nothing is adopted"        "no"  "$(said 'adopt:')"
ck "unreachable: says to re-run"            "yes" "$(said 'Re-run when it is reachable')"

# ── rc 1 + a failed adopt: stop, never fall through to node:<name> ───────────
# Falling through leaves .placementState local with the hint cleared, and the
# migrate then writes node:<name> from .node — the false membership assertion
# this whole guard exists to prevent.
out="$(run_guard 1 1)"
ck "adopt failed: the block stops"          "no"  "$(said 'continued:')"
ck "adopt failed: says the state stands"    "yes" "$(said 'Could not record the external placement')"

# ── the shell semantics this file exists for ─────────────────────────────────
# Documented as a test so the reason the guard is written `|| rc=$?` cannot be
# "simplified" away by someone reading the line in isolation.
bare="$(bash -c 'set -euo pipefail; f() { return 1; }; f; rc=$?; echo "reached"' 2>&1 || true)"
ck "bash: a bare call then rc=\$? aborts under set -e" "" "${bare}"
tested="$(bash -c 'set -euo pipefail; f() { return 1; }; rc=0; f || rc=$?; echo "reached rc=${rc}"' 2>&1 || true)"
ck "bash: the tested form survives and keeps rc"       "reached rc=1" "${tested}"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
