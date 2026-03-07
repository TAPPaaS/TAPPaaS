#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Snapshot
#
# Manages VM snapshots on the Proxmox cluster for an installed module.
#
# Usage: snapshot-vm.sh <module-name> [--list | --cleanup <N> | --restore <N>]
#
# Arguments:
#   module-name   Name of the module (must have config in ~/config)
#
# Options:
#   (none)          Create a new snapshot
#   --list          List all snapshots on the VM
#   --cleanup <N>   Delete all snapshots except the last N
#   --restore <N>   Restore snapshot N steps back in history (1 = most recent)
#
# Examples:
#   snapshot-vm.sh vaultwarden                # Create snapshot
#   snapshot-vm.sh vaultwarden --list         # List snapshots
#   snapshot-vm.sh vaultwarden --cleanup 3    # Keep only last 3
#   snapshot-vm.sh vaultwarden --restore 1    # Restore most recent snapshot
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'
readonly BOLD=$'\033[1m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: snapshot-vm.sh <module-name> [--list | --cleanup <N> | --restore <N>]

Options:
    (none)          Create a new snapshot
    --list          List all snapshots on the VM
    --cleanup <N>   Delete all snapshots except the last N
    --restore <N>   Restore snapshot N steps back in history (1 = most recent)
    -h, --help      Show this help message
EOF
}

# ── Arguments ────────────────────────────────────────────────────────

if [[ -z "${1:-}" || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

MODULE="$1"
shift

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly MGMT="mgmt"

# ── Validate module config ───────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON} — is '${MODULE}' installed?"
fi

VMID=$(jq -r '.vmid // empty' "${MODULE_JSON}")
NODE=$(jq -r '.node // "tappaas1"' "${MODULE_JSON}")
VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
[[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"

if [[ -z "${VMID}" ]]; then
    die "No vmid defined in ${MODULE_JSON}"
fi

NODE_FQDN="${NODE}.${MGMT}.internal"

# Verify VM exists
if ! ssh -o ConnectTimeout=5 root@"${NODE_FQDN}" "qm status ${VMID}" &>/dev/null; then
    die "VM ${VMID} (${VMNAME}) not found on node ${NODE}"
fi

# ── Parse action ─────────────────────────────────────────────────────

ACTION="create"
ACTION_ARG=""

if [[ -n "${1:-}" ]]; then
    case "$1" in
        --list)
            ACTION="list"
            ;;
        --cleanup)
            ACTION="cleanup"
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                die "--cleanup requires a positive integer argument"
            fi
            ACTION_ARG="$2"
            ;;
        --restore)
            ACTION="restore"
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
                die "--restore requires a positive integer argument (1 = most recent)"
            fi
            ACTION_ARG="$2"
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
fi

info "snapshot-vm for ${BL}${VMNAME}${CL} (VMID: ${VMID}) on ${NODE} — action: ${BOLD}${ACTION}${CL}"

# ── Helper: get sorted snapshot names ────────────────────────────────

get_snapshot_names() {
    # qm listsnapshot outputs lines like:
    #   `-> snapname   date   description
    # Filter out "current" which is not a real snapshot
    ssh root@"${NODE_FQDN}" "qm listsnapshot ${VMID}" 2>/dev/null \
        | grep -v '^\s*$' \
        | sed 's/^[[:space:]`|>+\-]*//g' \
        | awk '{print $1}' \
        | grep -v '^current$' \
        | grep -v '^$'
}

# ── Actions ──────────────────────────────────────────────────────────

case "${ACTION}" in

    create)
        SNAP_NAME="tappaas-$(date +'%Y%m%d-%H%M%S')"
        SNAP_DESC="TAPPaaS snapshot for ${MODULE}"
        info "  Creating snapshot: ${BL}${SNAP_NAME}${CL}"
        ssh root@"${NODE_FQDN}" "qm snapshot ${VMID} '${SNAP_NAME}' --description '${SNAP_DESC}'" \
            || die "Failed to create snapshot"
        info "${GN}Snapshot '${SNAP_NAME}' created successfully${CL}"
        ;;

    list)
        info "  Snapshots for VM ${VMNAME} (${VMID}):"
        echo ""
        ssh root@"${NODE_FQDN}" "qm listsnapshot ${VMID}" 2>/dev/null || die "Failed to list snapshots"
        echo ""
        ;;

    cleanup)
        KEEP="${ACTION_ARG}"
        SNAPSHOTS=$(get_snapshot_names)
        SNAP_COUNT=$(echo "${SNAPSHOTS}" | grep -c . || true)

        if [[ "${SNAP_COUNT}" -le "${KEEP}" ]]; then
            info "  ${SNAP_COUNT} snapshot(s) found, keeping ${KEEP} — nothing to delete"
            exit 0
        fi

        DELETE_COUNT=$((SNAP_COUNT - KEEP))
        # Delete oldest snapshots (top of list = oldest)
        TO_DELETE=$(echo "${SNAPSHOTS}" | head -n "${DELETE_COUNT}")

        info "  Found ${SNAP_COUNT} snapshots, keeping last ${KEEP}, deleting ${DELETE_COUNT}"
        while IFS= read -r snap; do
            [[ -z "${snap}" ]] && continue
            info "  Deleting snapshot: ${BL}${snap}${CL}"
            ssh root@"${NODE_FQDN}" "qm delsnapshot ${VMID} '${snap}'" \
                || warn "Failed to delete snapshot '${snap}'"
        done <<< "${TO_DELETE}"

        info "${GN}Cleanup completed — ${DELETE_COUNT} snapshot(s) removed${CL}"
        ;;

    restore)
        STEPS_BACK="${ACTION_ARG}"
        SNAPSHOTS=$(get_snapshot_names)
        SNAP_COUNT=$(echo "${SNAPSHOTS}" | grep -c . || true)

        if [[ "${SNAP_COUNT}" -eq 0 ]]; then
            die "No snapshots found for VM ${VMNAME}"
        fi

        if [[ "${STEPS_BACK}" -gt "${SNAP_COUNT}" ]]; then
            die "Requested ${STEPS_BACK} steps back but only ${SNAP_COUNT} snapshot(s) exist"
        fi

        # Get the snapshot N steps back from the end (tail gives newest-first order reversed)
        TARGET=$(echo "${SNAPSHOTS}" | tail -n "${STEPS_BACK}" | head -n 1)

        if [[ -z "${TARGET}" ]]; then
            die "Could not determine target snapshot"
        fi

        warn "Restoring VM ${VMNAME} (${VMID}) to snapshot: ${BOLD}${TARGET}${CL}"
        warn "This will stop the VM and roll back to the snapshot state."

        # Stop VM before rollback
        info "  Stopping VM ${VMID}..."
        ssh root@"${NODE_FQDN}" "qm stop ${VMID}" 2>/dev/null || true
        sleep 3

        info "  Rolling back to snapshot: ${BL}${TARGET}${CL}"
        ssh root@"${NODE_FQDN}" "qm rollback ${VMID} '${TARGET}'" \
            || die "Failed to rollback to snapshot '${TARGET}'"

        info "  Starting VM ${VMID}..."
        ssh root@"${NODE_FQDN}" "qm start ${VMID}" \
            || die "Failed to start VM after rollback"

        info "${GN}VM ${VMNAME} restored to snapshot '${TARGET}' and started${CL}"
        ;;
esac
