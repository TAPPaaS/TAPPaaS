#!/usr/bin/env bash
#
# Unit tests for the pure CSV helpers in pbs-job.sh (issue #200).
# No cluster access — exercises the vmid-list add/remove/has logic only.
#
# Usage: ./test-pbs-job.sh   (exit 0 = all passed)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging stubs + CONFIG_DIR so the lib sources standalone.
info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
# shellcheck disable=SC2034  # read by the sourced pbs-job.sh (PBS_CONFIG_DIR)
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }

# shellcheck source=pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-job.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
ck_rc() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp rc $2 got $3)"; FAIL=$((FAIL+1)); fi; }

# ── _pbs_csv_has ─────────────────────────────────────────────────────
_pbs_csv_has "140,150,310" 150 && r=0 || r=1; ck_rc "has present"        0 "$r"
_pbs_csv_has "140,150,310" 311 && r=0 || r=1; ck_rc "has absent"         1 "$r"
_pbs_csv_has "140,150,310" 14  && r=0 || r=1; ck_rc "has no substr match" 1 "$r"   # 14 must not match 140
_pbs_csv_has "" 140               && r=0 || r=1; ck_rc "has on empty"      1 "$r"
_pbs_csv_has "140" 140            && r=0 || r=1; ck_rc "has single"        0 "$r"

# ── _pbs_csv_add (dedup + numeric sort) ──────────────────────────────
ck "add to empty"      "140"             "$(_pbs_csv_add "" 140)"
ck "add new (sorted)"  "140,150,310"     "$(_pbs_csv_add "150,310" 140)"
ck "add duplicate"     "140,150,310"     "$(_pbs_csv_add "140,150,310" 150)"
ck "add numeric order" "90,140,1000"     "$(_pbs_csv_add "140,1000" 90)"

# ── _pbs_csv_remove ──────────────────────────────────────────────────
ck "remove middle"     "140,310"         "$(_pbs_csv_remove "140,150,310" 150)"
ck "remove last→empty" ""                "$(_pbs_csv_remove "140" 140)"
ck "remove absent"     "140,150"         "$(_pbs_csv_remove "140,150" 999)"
ck "remove no substr"  "140"             "$(_pbs_csv_remove "140" 14)"   # 14 must not remove 140

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
