#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# Find the branch version of TAPPaaS to use
if [ -z "$BRANCH" ]; then
  BRANCH="main"
fi

# clone the tappaas-cicd repo
echo -e "\nCloning TAPPaaS repository..."
git clone   https://github.com/TAPPaaS/TAPPaaS.git
echo -e "\nswitching to branch $BRANCH..."
cd TAPPaaS
git checkout $BRANCH

# go to the tappaas-cicd folder
echo -e "\nChanging to TAPPaaS-CICD directory and rebuilding the NixOS configuration..."
cd src/foundation/30-tappaas-cicd

# rebuild the nixos configuration
sudo nixos-rebuild switch -I nixos-config=./tappaas-cicd.nix

# creatae a fully qualified node hostname for tappaas1
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"
FIREWALL_FQDN="firewall.$MGMTVLAN.internal"

# create ssh keys for the tappaas user
echo -e "\nCreating SSH keys for the tappaas user and installing them for the proxmox host..."
ssh-keygen -t ed25519 -f /home/tappaas/.ssh/id_ed25519 -N "" -C "tappaas-cicd"
# enforce secure permissions on the private key
sudo chown tappaas:users /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519

# copy the public keys to the root account of every proxmox host
while read -r node; do
  echo -e "\nInstalling SSH public key on proxmox node: $node"
  NODE_FQDN="$node.$MGMTVLAN.internal"
  ssh-copy-id -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" || echo "SSH key copy to $node failed or key already installed."
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh root@"$NODE_FQDN" "mkdir -p /root/tappaas"
  scp /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub
  scp /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key
done < <(ssh root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

# create tappaas binary director and config directory
mkdir -p /home/tappaas/config
mkdir -p /home/tappaas/bin

# Add /home/tappaas/bin to PATH
# On NixOS, .profile is sourced for login shells, and we also add to .bashrc
# for interactive non-login shells that explicitly source it
TAPPAAS_PATH_EXPORT='export PATH="/home/tappaas/bin:$PATH"'
for rcfile in /home/tappaas/.profile /home/tappaas/.bashrc; do
    if ! grep -q '/home/tappaas/bin' "$rcfile" 2>/dev/null; then
        echo -e '\n# TAPPaaS bin directory' >> "$rcfile"
        echo "$TAPPAAS_PATH_EXPORT" >> "$rcfile"
        echo "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done
# copy the json configuration files 
cp /home/tappaas/TAPPaaS/src/foundation/*.json /home/tappaas/config/
cp ../*/*.json /home/tappaas/config/
# copy the potentially modified configuration.json and vlans.json files from tappaas1 (potentially modified during bootstrap)
scp root@"$NODE1_FQDN":/root/tappaas/*.json /home/tappaas/config/

# copy the jsons to all nodes
/home/tappaas/bin/copy-jsons.sh 


# run the update script as all update actions is also needed at install time
. ./update.sh

# Setup Caddy reverse proxy on the firewall
echo -e "\nSetting up Caddy reverse proxy..."
/home/tappaas/bin/setup-caddy.sh || {
    echo "Warning: Caddy setup encountered issues. Please review and complete manually."
}

echo -e "\nTAPPaaS-CICD installation completed successfully."