#!/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# clone the tappaas-cicd repo
echo -e "\nCloning TAPPaaS repository..."
git clone   https://github.com/TAPPaaS/TAPPaaS.git

# go to the tappaas-cicd folder
echo -e "\nChanging to TAPPaaS-CICD directory and rebuilding the NixOS configuration..."
cd TAPPaaS/src/foundation/30-tappaas-cicd

# rebuild the nixos configuration
sudo nixos-rebuild switch -I nixos-config=./tappaas-cicd.nix

# create ssh keys for the tappaas user
echo -e "\nCreating SSH keys for the tappaas user and installing them for the proxmox host..."
ssh-keygen -t ed25519 -f /home/tappaas/.ssh/id_ed25519 -N "" -C "tappaas-cicd"
# enforce secure permissions on the private key
sudo chown tappaas:users /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519

# copy the public key to the root account of every proxmox host
while read -r node; do
  echo -e "\nInstalling SSH public key on proxmox node: $node"
  ssh-copy-id -i /home/tappaas/.ssh/id_ed25519.pub root@"$node".lan.internal
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh root@"$node".lan.internal "mkdir -p /root/tappaas"
  scp /home/tappaas/.ssh/id_ed25519.pub root@"$node".lan.internal:/root/tappaas/tappaas-cicd.pub
done < <(ssh root@tappaas1.lan.internal pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )


echo "\nTAPPaaS-CICD installation completed successfully."