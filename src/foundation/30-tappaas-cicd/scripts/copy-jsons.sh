#!/bin/env bash
#
# Copy config files to nodes.

# creatae a fully qualified node hostname for tappaas1
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"

# itterate over every proxmox host
while read -r node; do
  echo -e "\nInstalling .jsons on proxmox node: $node"
  NODE_FQDN="$node.$MGMTVLAN.internal"
  scp /home/tappaas/config/*.json root@"$NODE_FQDN":/root/tappaas/
  ssh root@"$NODE_FQDN" chmod 444 /root/tappaas/*.json
done < <(ssh root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )
