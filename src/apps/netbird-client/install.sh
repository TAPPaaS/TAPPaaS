#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# < Update the following lines to match your project, current code is generic example code that works for many modules >
# install and configure a Module
# It assumes that you are in the install directory

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONENAME="mgmt"


# copy the VM template
scp "$1.json" "root@${NODE}.${ZONENAME}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${ZONENAME}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"

ssh "root@${VMNAME}.${ZONENAME}.internal" "apt update && apt upgrade -y && apt install curl -y"
# ssh "root@${VMNAME}.${ZONENAME}.internal" "curl -fsSL https://pkgs.netbird.io/install.sh | sh"

/home/tappaas/bin/update-HA.sh $1

echo -e "\nVM installation completed successfully."