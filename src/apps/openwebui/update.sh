#!/usr/bin/env bash
#
# TAPPaaS OpenWebUI Module Update
#
# Post-rebuild steps for the OpenWebUI module. Called after update-os.sh
# has applied nixos-rebuild switch and the VM has rebooted.
#
# Runs health checks to verify the upgrade succeeded, then prunes
# unused container images. If health checks fail, old images are
# preserved for rollback.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh openwebui
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' 'NONE')"
readonly VMNAME VMID NODE ZONE0NAME HANODE

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── Helper functions ──────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Post-rebuild update steps for OpenWebUI module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} openwebui
EOF
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    echo ""
    info "=== OpenWebUI Post-Update ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"

    # ── Step 1: Run health checks ─────────────────────────────────────
    info ""
    info "Step 1: Verify upgrade health"

    if "${SCRIPT_DIR}/test.sh" "${VMNAME}"; then
        info "Health checks passed — upgrade confirmed healthy"
    else
        error "Health checks FAILED — skipping image prune to preserve rollback capability"
        error "Old container images retained on ${VM_HOST}"
        exit 1
    fi

    # ── Step 2: Prune unused container images ─────────────────────────
    info ""
    info "Step 2: Prune unused container images"

    local prune_output
    # shellcheck disable=SC2086
    prune_output=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo podman image prune -a -f" 2>&1) || true

    if [[ -n "${prune_output}" ]]; then
        info "Pruned images:"
        echo "${prune_output}" | while IFS= read -r line; do
            info "  ${line}"
        done
    else
        info "No unused images to prune"
    fi

    # ── Done ──────────────────────────────────────────────────────────
    echo ""
    info "=== Update Complete ==="
    info "VM: ${VMNAME} (VMID: ${VMID})"
    info "Node: ${NODE}"
    info "Zone: ${ZONE0NAME}"
    if [[ -n "${HANODE}" && "${HANODE}" != "NONE" ]]; then
        info "HA Node: ${HANODE}"
    fi
}

main "$@"
