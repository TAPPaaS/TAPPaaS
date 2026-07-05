#!/usr/bin/env bash
#
# Unit tests for the pure helpers in pbs-push.sh (ADR-012 P4). No cluster access.
# Cluster ops (pvesm add/remove/status over ssh) are not unit-testable; this
# covers the storage-name derivation the rest of the push path keys off.
#
# Usage: ./test-pbs-push.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BL=""; GN=""
# shellcheck disable=SC2034
CONFIG_DIR="/tmp/nonexistent-$$"
get_node_hostname() { echo "tappaas1"; }

# shellcheck source=pbs-push.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-push.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

# ── _pbs_push_storage_name ───────────────────────────────────────────
ck "storage name: offsite"  "offsite-offsite" "$(_pbs_push_storage_name offsite)"
ck "storage name: buddy"    "offsite-buddy"   "$(_pbs_push_storage_name buddy)"
ck "storage name: with dash" "offsite-my-site" "$(_pbs_push_storage_name my-site)"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
