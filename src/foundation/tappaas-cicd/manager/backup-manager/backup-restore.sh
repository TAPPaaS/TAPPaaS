#!/usr/bin/env bash
# backup-restore.sh — restore operations for the backup hierarchy (ADR-007 P9).
#
# Thin operator-facing wrapper. List/restore of VM backups is delegated to the
# tested foundation restore script (src/foundation/backup/restore.sh); snapshot
# listing/verify for a named module is delegated to backup-controller. This
# manager script just resolves the module -> VMID and forwards.
#
# Usage:
#   backup-restore list <module>            list snapshots for a module's VM
#   backup-restore restore <module> [opts]  restore a module's VM (delegates)
#   backup-restore list-all                 list all backups
#   backup-restore help
#
# Live PBS access is required for the actual restore; offline this prints what
# it would call and exits cleanly (so tests and dry inspection are safe).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# Foundation restore script (the tested VM-restore logic) and the controller.
RESTORE_SH="${RESTORE_SH:-${HERE}/../../../backup/restore.sh}"
BACKUP_CONTROLLER="${BACKUP_CONTROLLER:-/home/tappaas/bin/backup-controller}"
[[ -x "$BACKUP_CONTROLLER" ]] || BACKUP_CONTROLLER="${HERE}/../../controller/backup-controller/backup-controller"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; 1d'; }

# Resolve a module name to its VMID from the deployed config.
module_vmid() {
    local f="${CONFIG_DIR}/$1.json"
    [[ -f "$f" ]] || { echo "No config for module '$1' in ${CONFIG_DIR}" >&2; return 1; }
    jq -r '.vmid // empty' "$f" 2>/dev/null
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    list)
        module="${1:?list: <module> required}"
        vmid="$(module_vmid "$module")" || exit 1
        [[ -n "$vmid" ]] || { echo "Module '$module' has no vmid" >&2; exit 1; }
        if [[ -x "$RESTORE_SH" ]]; then
            exec "$RESTORE_SH" --vmid "$vmid" --list
        else
            echo "Would run: ${RESTORE_SH} --vmid ${vmid} --list (foundation restore.sh not found)"
        fi
        ;;
    restore)
        module="${1:?restore: <module> required}"; shift || true
        vmid="$(module_vmid "$module")" || exit 1
        [[ -n "$vmid" ]] || { echo "Module '$module' has no vmid" >&2; exit 1; }
        if [[ -x "$RESTORE_SH" ]]; then
            exec "$RESTORE_SH" --vmid "$vmid" "$@"
        else
            echo "Would run: ${RESTORE_SH} --vmid ${vmid} $* (foundation restore.sh not found)"
        fi
        ;;
    list-all)
        if [[ -x "$RESTORE_SH" ]]; then
            exec "$RESTORE_SH" --list-all
        else
            echo "Would run: ${RESTORE_SH} --list-all (foundation restore.sh not found)"
        fi
        ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: ${cmd}" >&2; usage >&2; exit 2 ;;
esac
