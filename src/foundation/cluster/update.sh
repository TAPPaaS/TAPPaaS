#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Update
#
# Distributes Create-TAPPaaS-VM.sh and zones.json to all Proxmox nodes
# in the cluster. This ensures every node has the latest VM creation
# script and zone definitions.
#
# Usage: ./update.sh [vmname]
#

set -euo pipefail

MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\nStarting TAPPaaS Cluster module update..."

# Iterate through all TAPPaaS nodes and copy Create-TAPPaaS-VM.sh to /root/tappaas
echo -e "\nCopying zones.json and Create-TAPPaaS-VM.sh to /root/tappaas on all Proxmox nodes..."
while read -r node; do
    echo -e "\nCopying zones.json and Create-TAPPaaS-VM.sh to /root/tappaas on node: $node"
    NODE_FQDN="$node.$MGMTVLAN.internal"
    scp /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/
done < <(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" "pvesh get /cluster/resources --type node --output-format json | jq --raw-output \".[].node\"")
echo -e "\nCreate-TAPPaaS-VM.sh copied to all Proxmox nodes."

echo -e "\nCluster module update completed successfully."
