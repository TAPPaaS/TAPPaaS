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

# ── Shared library ────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

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

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly MGMT="mgmt"

# ── Validate module config ───────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON} — is '${MODULE}' installed?"
fi

VMID=$(get_config_value 'vmid' '')
NODE=$(get_config_value 'node' '')
[[ -z "${NODE}" ]] && NODE="$(get_node_hostname 0)"
VMNAME=$(get_config_value 'vmname' '')
[[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"

if [[ -z "${VMID}" ]]; then
    die "No vmid defined in ${MODULE_JSON}"
fi

NODE_FQDN="${NODE}.${MGMT}.internal"

# Detect whether VMID is a QEMU VM or LXC container
VM_TYPE=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR root@"${NODE_FQDN}" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
    | jq -r --argjson id "${VMID}" \
        '.[] | select(.vmid == $id) | .type // empty' 2>/dev/null || true)

if [[ -z "${VM_TYPE}" ]]; then
    die "VM ${VMID} (${VMNAME}) not found on node ${NODE}"
fi

# qm for QEMU VMs, pct for LXC containers
CMD="qm"
[[ "${VM_TYPE}" == "lxc" ]] && CMD="pct"

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
    # qm/pct listsnapshot outputs lines like:
    #   `-> snapname   date   description
    # Filter out "current" which is not a real snapshot
    ssh root@"${NODE_FQDN}" "${CMD} listsnapshot ${VMID}" 2>/dev/null \
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
        ssh root@"${NODE_FQDN}" "${CMD} snapshot ${VMID} '${SNAP_NAME}' --description '${SNAP_DESC}'" \
            || die "Failed to create snapshot"
        info "${GN}Snapshot '${SNAP_NAME}' created successfully${CL}"
        ;;

    list)
        info "  Snapshots for VM ${VMNAME} (${VMID}):"
        echo ""
        ssh root@"${NODE_FQDN}" "${CMD} listsnapshot ${VMID}" 2>/dev/null || die "Failed to list snapshots"
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
            ssh root@"${NODE_FQDN}" "${CMD} delsnapshot ${VMID} '${snap}'" \
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
        ssh root@"${NODE_FQDN}" "${CMD} stop ${VMID}" 2>/dev/null || true
        sleep 3

        info "  Rolling back to snapshot: ${BL}${TARGET}${CL}"
        ssh root@"${NODE_FQDN}" "${CMD} rollback ${VMID} '${TARGET}'" \
            || die "Failed to rollback to snapshot '${TARGET}'"

        info "  Starting VM ${VMID}..."
        ssh root@"${NODE_FQDN}" "${CMD} start ${VMID}" \
            || die "Failed to start VM after rollback"

        # A restore must return a USABLE VM, not merely a started one. Otherwise
        # the caller's post-restore verification races the guest boot and a
        # perfectly good rollback looks like a failure — e.g. update-module.sh's
        # post-rollback test, or cluster:vm's test-service which pings the guest
        # and is fatal if it's unreachable (#307). For QEMU VMs with the guest
        # agent, wait for it to respond (proves the OS is up and networking is
        # live), then a short settle so sshd/ICMP are ready. Agent-less VMs and
        # LXC fall back to a fixed grace period.
        agent_on=0
        if [[ "${CMD}" == "qm" ]] \
           && ssh root@"${NODE_FQDN}" "qm config ${VMID}" 2>/dev/null \
                | grep -q '^agent:.*1'; then
            agent_on=1
        fi
        if [[ "${agent_on}" -eq 1 ]]; then
            info "  Waiting for guest agent on VM ${VMID} to respond..."
            waited=0
            up=0
            while [[ "${waited}" -lt 180 ]]; do
                if ssh root@"${NODE_FQDN}" "qm guest cmd ${VMID} ping" >/dev/null 2>&1; then
                    up=1
                    break
                fi
                sleep 5
                waited=$((waited + 5))
            done
            if [[ "${up}" -eq 1 ]]; then
                info "  ${GN}Guest agent responding after ${waited}s — settling...${CL}"
                sleep 20
            else
                warn "  Guest agent did not respond within 180s — proceeding anyway"
            fi
        else
            info "  No guest agent detected — waiting 45s grace period for boot..."
            sleep 45
        fi

        info "${GN}VM ${VMNAME} restored to snapshot '${TARGET}' and started${CL}"
        ;;
esac
