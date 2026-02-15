#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

#
# creatae a fully qualified node hostname for tappaas1
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"
export FIREWALL_FQDN="firewall.$MGMTVLAN.internal"  # Used by sourced scripts

# copy the public keys to the root account of every proxmox host
while read -r node; do
  echo -e "\nInstalling SSH public key on proxmox node: $node"
  NODE_FQDN="$node.$MGMTVLAN.internal"
  ssh-copy-id -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" < /dev/null || echo "SSH key copy to $node failed or key already installed."
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh -n root@"$NODE_FQDN" "mkdir -p /root/tappaas"
  scp /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub < /dev/null
  scp /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key < /dev/null
done < <(ssh -n root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

# create tappaas binary director and config directory
mkdir -p /home/tappaas/config
mkdir -p /home/tappaas/bin

# Add /home/tappaas/bin to PATH
# On NixOS, .profile is sourced for login shells, and we also add to .bashrc
# for interactive non-login shells that explicitly source it
TAPPAAS_PATH_EXPORT='export PATH="/home/tappaas/bin:$PATH"'

# Export PATH for the current script execution
export PATH="/home/tappaas/bin:$PATH"

for rcfile in /home/tappaas/.profile /home/tappaas/.bashrc; do
    if ! grep -q '/home/tappaas/bin' "$rcfile" 2>/dev/null; then
        echo -e '\n# TAPPaaS bin directory' >> "$rcfile"
        echo "$TAPPAAS_PATH_EXPORT" >> "$rcfile"
        echo "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done

# create the configuration.json
if [ -f ./scripts/create-configuration.sh ]; then
  . ./scripts/create-configuration.sh
else
  echo "Error: ./scripts/create-configuration.sh not found"
  exit 1
fi 

# copy the potentially modified configuration.json and vlans.json files from tappaas1 (potentially modified during bootstrap)
scp root@"$NODE1_FQDN":/root/tappaas/*.json /home/tappaas/config/

# Setup Caddy reverse proxy on the firewall
echo -e "\nSetting up Caddy reverse proxy..."
/home/tappaas/bin/setup-caddy.sh || {
    echo "Warning: Caddy setup encountered issues. Please review and complete manually."
}

# run the update script as all update actions is also needed at install time
if [ -f /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update.sh ]; then
  . /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update.sh
else
  echo "Error: /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update.sh not found"
  exit 1
fi

echo -e "\nTAPPaaS-CICD installation completed successfully."