#!/bin/env bash
#
# <insert name of VM here>, update all references to <VM-NAME>, and any additional configuratoins needed
# install and configure a VM: 
# It assume that you are in the install directoy

. /home/tappaas/bin/common-install-rutines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
VLANTAG0NAME="$(get_config_value 'vlantag0' 'tappaas')"

# copy the VM template
scp $1.json root@${NODE}.tappaas.internal:/root/tappaas/$1.json
ssh root@${NODE}.tappaas.internal "/root/tappaas/Create-TAPPaaS-VM.sh $1"

# rebuild the nixos configuration
nixos-rebuild --target-host tappaas@$1.$VLANTAG0NAME.internal --use-remote-sudo switch -I nixos-config=./$1.nix

echo "VM installation completed successfully."