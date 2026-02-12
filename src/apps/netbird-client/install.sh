#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# < Update the following lines to match your project, current code is generic example code that works for many modules >
# install and configure a Module
# It assumes that you are in the install directory

. /home/tappaas/bin/install-vm.sh

sleep 60
ssh "root@${VMNAME}.${ZONENAME}.internal" "apt update && apt upgrade -y && apt install curl -y"
# ssh "root@${VMNAME}.${ZONENAME}.internal" "curl -fsSL https://pkgs.netbird.io/install.sh | sh"

/home/tappaas/bin/update-HA.sh $1

echo -e "\nVM installation completed successfully."