#!/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# Find the branch version of TAPPaaS to use
if [ -z $BRANCH]; then
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
cd TAPPaaS/src/foundation/30-tappaas-cicd

# rebuild the nixos configuration
sudo nixos-rebuild switch -I nixos-config=./tappaas-cicd.nix

# creatae a fully qualified node hostname for tappaas1
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"

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
mkdir -p /home/tappaas/bin
mkdir -p /home/tappaas/config
cp TAPPaaS/src/foundation/30-tappaas-cicd/scripts/*.sh /home/tappaas/bin/
chmod +x /home/tappaas/bin/*.sh
cp TAPPaaS/src/foundation/*/*.json /home/tappaas/config/
# copy the potentially modified configuration.json and vlans.json files from tappaas1
scp root@"$NODE1_FQDN":/root/tappaas/*.json /home/tappaas/config/

# copy the jsons to all nodes
/users/tappaas/bin/copy-jsons.sh 

echo "\nTAPPaaS-CICD installation completed successfully."