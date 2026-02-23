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

MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\nStarting TAPPaaS Cluster module update..."

# Get list of all cluster nodes
echo -e "\nDiscovering Proxmox cluster nodes..."
NODES=$(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[].node'")
echo "Found nodes: $(echo "$NODES" | tr '\n' ' ')"

# Step 1: Run apt update && apt upgrade on all Proxmox nodes
echo -e "\n--- Step 1: Updating Proxmox node packages ---"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo -e "\nRunning apt update on $node..."
    if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update"; then
        echo "Warning: apt update failed on $node"
        continue
    fi
    echo "Running apt upgrade on $node..."
    if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt upgrade --assume-yes"; then
        echo "Warning: apt upgrade failed on $node"
        continue
    fi
    echo "$node package update completed."
done <<< "$NODES"
echo -e "\nAll Proxmox nodes package update completed."

# Step 2: Distribute files to all nodes
echo -e "\n--- Step 2: Distributing files to all Proxmox nodes ---"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo -e "\nCopying zones.json and Create-TAPPaaS-VM.sh to $node..."
    scp /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/
done <<< "$NODES"
echo -e "\nFiles distributed to all Proxmox nodes."

echo -e "\nCluster module update completed successfully."
