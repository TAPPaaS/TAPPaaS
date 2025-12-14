#!/bin/env bash
#
# <insert name of VM here>, update all references to <VM-NAME>, and any additional configuratoins needed
# install and configure a VM: 
# It assume that you are in the install directoy

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# copy the VM template
scp <VM-NAME>.json root@tappaas1.internal:/root/tappaas/<VM-NAME>.json
ssh root@tappaas1.internal "/root/tappaas/Create-TAPPaaS-VM.sh <VM-NAME>"

# rebuild the nixos configuration
nixos-rebuild --target-host tappaas@<VM-NAME>.internal --use-remote-sudo switch -I nixos-config=./<VM-NAME.nix


echo "VM installation completed successfully."