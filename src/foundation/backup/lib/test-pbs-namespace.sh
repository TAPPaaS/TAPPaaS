#!/usr/bin/env bash
#
# Unit tests for the pure helpers in pbs-namespace.sh (issue #227).
# No cluster access — exercises ACL-path, parent-chain and retention-arg logic.
#
# Usage: ./test-pbs-namespace.sh   (exit 0 = all passed)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging + dependency stubs so the lib sources standalone.
info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
pbs_node() { echo "tappaas3"; }
pbs_storage_name() { echo "tappaas_backup"; }

# shellcheck source=pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-namespace.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

# ── _pbs_ns_acl_path ─────────────────────────────────────────────────
ck "acl root"        "/datastore/tappaas_backup"             "$(_pbs_ns_acl_path tappaas_backup '')"
ck "acl remote"      "/datastore/tappaas_backup/remote/lars" "$(_pbs_ns_acl_path tappaas_backup remote/lars)"
ck "acl external"    "/datastore/tappaas_backup/external/synology" "$(_pbs_ns_acl_path tappaas_backup external/synology)"

# ── _pbs_ns_parents (outermost first) ────────────────────────────────
ck "parents single"  "remote"               "$(_pbs_ns_parents remote | paste -sd',' -)"
ck "parents nested"  "remote,remote/lars"   "$(_pbs_ns_parents remote/lars | paste -sd',' -)"
ck "parents deep"    "a,a/b,a/b/c"          "$(_pbs_ns_parents a/b/c | paste -sd',' -)"

# ── _pbs_retention_args ──────────────────────────────────────────────
ck "retention full" "--keep-last 4 --keep-daily 14 --keep-weekly 8 --keep-monthly 12" \
   "$(_pbs_retention_args '{"keepLast":4,"keepDaily":14,"keepWeekly":8,"keepMonthly":12}')"
ck "retention partial" "--keep-daily 7 --keep-weekly 4 --keep-monthly 3" \
   "$(_pbs_retention_args '{"keepDaily":7,"keepWeekly":4,"keepMonthly":3}')"
ck "retention empty" "" "$(_pbs_retention_args '{}')"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
