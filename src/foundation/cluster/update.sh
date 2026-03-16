#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Update
#
# Updates all Proxmox nodes in the cluster:
#   1. Runs apt update && apt upgrade on each node
#   2. Distributes Create-TAPPaaS-VM.sh and zones.json to each node
#
# Usage: ./update.sh [module-name]
#
# Arguments:
#   module-name   (optional) Passed by update-module.sh, not used by this script
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "Starting TAPPaaS Cluster module update..."

# Get list of all cluster nodes
echo ""
info "Discovering Proxmox cluster nodes..."
NODES=$(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[].node'")
info "Found nodes: $(echo "$NODES" | tr '\n' ' ')"

# Step 1: Run apt update && apt upgrade on all Proxmox nodes
echo ""
info "${BOLD}Step 1: Updating Proxmox node packages${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo ""
    info "Running apt update on $node..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update"; then
            warn "apt update failed on $node"
            continue
        fi
    else
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt update failed on $node"
            continue
        fi
        echo ""
    fi
    info "Running apt upgrade on $node..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt upgrade --assume-yes"; then
            warn "apt upgrade failed on $node"
            continue
        fi
    else
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt upgrade --assume-yes" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt upgrade failed on $node"
            continue
        fi
        echo ""
    fi
    info "$node package update completed."
done <<< "$NODES"
echo ""
info "All Proxmox nodes package update completed."

# Step 2: Distribute files to all nodes
echo ""
info "${BOLD}Step 2: Distributing files to all Proxmox nodes${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo ""
    info "Copying zones.json and Create-TAPPaaS-VM.sh to $node..."
    scp /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/
done <<< "$NODES"
echo ""
info "Files distributed to all Proxmox nodes."

echo ""
info "${GN}✓${CL} Cluster module update completed successfully."
