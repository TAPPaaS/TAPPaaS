#!/usr/bin/env bash
#
# Unit tests for the pure helpers in pbs-immutable.sh (ADR-012 §3.5 / #389).
# No cluster access — dataset derivation + OnCalendar mapping. The node ops
# (systemd timer install over ssh) are not unit-testable.
#
# Usage: ./test-pbs-immutable.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { :; }; warn() { :; }; error() { echo "ERR: $*" >&2; }; debug() { :; }
BOLD=""; CL=""; BL=""; GN=""
# shellcheck disable=SC2034
CONFIG_DIR="/tmp/nonexistent-$$"
pbs_node() { echo "tappaas1"; }
pbs_storage_name() { echo "tappaas_backup"; }

# shellcheck source=pbs-immutable.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-immutable.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

# ── _pbs_dataset_from_path (strip leading slash) ─────────────────────
ck "dataset: tankc pool"  "tankc1/tappaas_backup" "$(_pbs_dataset_from_path /tankc1/tappaas_backup)"
ck "dataset: nested"      "tanka1/sub/ds"         "$(_pbs_dataset_from_path /tanka1/sub/ds)"
ck "dataset: no slash"    "already/rel"           "$(_pbs_dataset_from_path already/rel)"

# ── _pbs_immutable_oncalendar (friendly → calendar, else passthrough) ─
ck "cal: hourly"  "hourly"          "$(_pbs_immutable_oncalendar hourly)"
ck "cal: daily"   "daily"           "$(_pbs_immutable_oncalendar daily)"
ck "cal: weekly"  "weekly"          "$(_pbs_immutable_oncalendar weekly)"
ck "cal: raw expr" "*-*-* 02:30:00" "$(_pbs_immutable_oncalendar '*-*-* 02:30:00')"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
