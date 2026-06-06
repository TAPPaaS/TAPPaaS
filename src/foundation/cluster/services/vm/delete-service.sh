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

# VMID/NODE may be overridden by delete-module.sh after it has resolved the
# exact target VM (handles multiple instances of the same module and a stale
# .node after HA migration). Falls back to the module config. See issue #195.
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
NODE="${TAPPAAS_NODE_OVERRIDE:-$(get_config_value 'node' "$(get_node_hostname 0)")}"
VMNAME=$(get_config_value 'vmname' "${MODULE_NAME}")
ZONE0NAME=$(get_config_value 'zone0' 'mgmt')

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

# Remove any DNS pin / static DHCP reservation created at install time for
# appliance (cloudInit:false) or Windows VMs. Harmless no-op for cloud-init VMs
# (they self-register via the lease and have no pin) and when none exists.
# Without this the dnsmasq dhcp-host=<mac>,<ip>,<vmname> reservation would linger
# after the VM is gone and could mis-route a future guest that reuses the IP/name.
if command -v dns-manager >/dev/null 2>&1; then
    info "  Removing any DNS pin/reservation for ${VMNAME}.${ZONE0NAME}.internal"
    dns-manager --no-ssl-verify delete "${VMNAME}" "${ZONE0NAME}.internal" >/dev/null 2>&1 \
        || debug "  no DNS record to remove for ${VMNAME}.${ZONE0NAME}.internal"
fi

info "VM ${VMNAME} (VMID: ${VMID}) destroyed successfully"
