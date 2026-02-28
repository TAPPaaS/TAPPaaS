#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Delete
#
# Stops and destroys a VM on the Proxmox cluster for a consuming module.
#
# Usage: delete-service.sh <module-name>
# Arguments:
#   module-name - Name of the module whose VM should be destroyed
#                 (must have a <module-name>.json in /home/tappaas/config)
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Destroys the VM for the specified module."
    exit 1
fi

. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="$1"
MGMTVLAN="mgmt"

VMID=$(get_config_value 'vmid')
NODE=$(get_config_value 'node' 'tappaas1')
VMNAME=$(get_config_value 'vmname' "${MODULE_NAME}")

NODE_FQDN="${NODE}.${MGMTVLAN}.internal"

info "Destroying VM ${VMNAME} (VMID: ${VMID}) on node ${NODE}..."

# Check if VM exists
if ! ssh root@"${NODE_FQDN}" "qm status ${VMID}" &>/dev/null; then
    warn "VM ${VMID} does not exist on node ${NODE} — nothing to destroy"
    exit 0
fi

# Stop the VM (ignore errors if already stopped)
info "  Stopping VM ${VMID}..."
ssh root@"${NODE_FQDN}" "qm stop ${VMID}" 2>/dev/null || true

# Wait briefly for stop to complete
sleep 3

# Destroy the VM with --purge to remove all associated data
info "  Destroying VM ${VMID} with --purge..."
ssh root@"${NODE_FQDN}" "qm destroy ${VMID} --purge" || {
    error "Failed to destroy VM ${VMID}"
    exit 1
}

info "VM ${VMNAME} (VMID: ${VMID}) destroyed successfully"
