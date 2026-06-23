#!/usr/bin/env bash
# check-backup-status.sh — read-only backup-health check (ADR-007 P9).
#
# Calls `backup-manager status` and reports modules whose backup is DISABLED or
# that are NOT wired into the shared PBS job while still expected to be backed
# up. Designed for cron / health dashboards: read-only, never mutates config or
# contacts PBS directly (it reads backup-manager's resolved policy).
#
# Usage: check-backup-status.sh [--config-dir DIR] [--quiet]
# Exit:  0 = all enabled modules covered; 1 = one or more flagged.
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir) CONFIG_DIR="$2"; export CONFIG_DIR; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; 1d'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Resolve the backup-manager status entry: prefer the linked bin, else sibling.
BM="$(command -v backup-manager 2>/dev/null || true)"
if [[ -z "$BM" ]]; then
    BM="$(cd "$(dirname "${BASH_SOURCE[0]}")/../backup-manager" 2>/dev/null && pwd)/backup-manager.sh"
fi
if [[ ! -x "$BM" && ! -f "$BM" ]]; then
    echo "[backup-health] backup-manager not available — skipping" >&2
    exit 0
fi

# `backup-manager status` prints a table; use backup-status.sh --json for
# machine parsing. Resolve it the same way as the manager.
ST="$(command -v backup-status.sh 2>/dev/null || true)"
[[ -n "$ST" ]] || ST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../backup-manager" 2>/dev/null && pwd)/backup-status.sh"
arr="$("$ST" --config-dir "$CONFIG_DIR" --json 2>/dev/null || echo '[]')"

disabled="$(jq -r '[.[] | select(.enabled==false) | .module] | join(", ")' <<<"$arr" 2>/dev/null || echo "")"
# "Overdue/uncovered": enabled but NOT in the PBS job (expected coverage gap).
uncovered="$(jq -r '[.[] | select(.enabled==true and .inPbsJob==false) | .module] | join(", ")' <<<"$arr" 2>/dev/null || echo "")"
total="$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)"

rc=0
if [[ -n "$disabled" ]]; then
    echo "[backup-health] DISABLED: ${disabled}"
    rc=1
fi
if [[ -n "$uncovered" ]]; then
    echo "[backup-health] enabled but NOT in PBS job: ${uncovered}"
    rc=1
fi
if [[ "$QUIET" -eq 0 ]]; then
    echo "[backup-health] ${total} module(s) checked; $( [[ $rc -eq 0 ]] && echo "all enabled modules covered" || echo "see flags above" )"
fi
exit "$rc"
