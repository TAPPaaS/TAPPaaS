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
scp pbs.json root@tappaas1.internal:/root/tappaas/pbs.json
ssh root@tappaas1.internal "/root/tappaas/Create-TAPPaaS-VM.sh pbs"

echo "VM create go to console to complete PBS installation"