#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Delete
#
# Stops and destroys an LXC container on the Proxmox cluster for a consuming
# module, and removes its DNS record. Sibling of cluster:vm delete-service.
#
# Usage: delete-service.sh <module-name>
#

# Remote pct commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Destroys the LXC container for the specified module."
    exit 1
fi

. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="$1"
MGMT="mgmt"

# VMID/NODE may be overridden by delete-module.sh after it resolves the exact
# target (multiple instances, stale .node). Mirrors cluster:vm (issue #195).
VMID="${TAPPAAS_VMID_OVERRIDE:-$(get_config_value 'vmid')}"
NODE="${TAPPAAS_NODE_OVERRIDE:-$(get_config_value 'node' "$(get_node_hostname 0)")}"
VMNAME="$(get_config_value 'vmname' "${MODULE_NAME}")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"

NODE_FQDN="${NODE}.${MGMT}.internal"

info "Destroying LXC ${VMNAME} (VMID: ${VMID}) on node ${NODE}..."

if ! ssh root@"${NODE_FQDN}" "pct status ${VMID}" &>/dev/null; then
    warn "LXC ${VMID} does not exist on node ${NODE} — nothing to destroy"
else
    info "  Stopping LXC ${VMID}..."
    ssh root@"${NODE_FQDN}" "pct stop ${VMID}" 2>/dev/null || true
    sleep 3
    info "  Destroying LXC ${VMID} with --purge..."
    ssh root@"${NODE_FQDN}" "pct destroy ${VMID} --purge" || {
        error "Failed to destroy LXC ${VMID}"
        exit 1
    }
fi

# Remove the DNS record (harmless if absent — install may not have registered it).
info "  Removing DNS: ${VMNAME}.${ZONE0}.internal"
dns-manager --no-ssl-verify delete "${VMNAME}" "${ZONE0}.internal" \
    || debug "  no DNS record to remove for ${VMNAME}.${ZONE0}.internal"

info "LXC ${VMNAME} (VMID: ${VMID}) destroyed successfully"
