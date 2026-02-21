#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -e

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# rebuild the nixos configuration
sudo nixos-rebuild  switch -I "nixos-config=./${VMNAME}.nix"

/home/tappaas/bin/update-cron.sh
echo -e "\nupdate-tappaas cron job updated."

echo -e "\nVM update completed successfully."
