#!/usr/bin/env bash
# TAPPaaS Module Update Template
#
# < Update the following lines to match your project >
# Update a TAPPaaS Module
# It assumes that you are in the install directory

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' '$1')"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"

ssh "root@${NODE}.${ZONE0NAME}.internal" "apt update && apt upgrade -y && apt install curl -y"

# Update HA configuration (creates/updates/removes based on HANode field)
/home/tappaas/bin/update-HA.sh $1

echo -e "\nVM update completed successfully."