#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -e

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"
FIREWALL_FQDN="firewall.$MGMTVLAN.internal"
echo -e "\nStarting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# TODO: check if branch has changed and if so checkout the branch before pulling
cd
cd TAPPaaS || { echo "TAPPaaS directory not found!"; exit 1; }
echo -e "\nPulling latest changes from TAPPaaS repository..."
git pull origin
# get to the right directory
cd src/foundation/30-tappaas-cicd || { echo "TAPPaaS-CICD directory not found!"; exit 1; }

# in case there are new or updated scripts 
cp scripts/*.sh /home/tappaas/bin/
chmod +x /home/tappaas/bin/*.sh

# (re)Build the opnsense-controller project (formerly opnsense-scripts)
echo -en "\nBuilding the opnsense-controller project"
cd opnsense-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/opnsense-controller-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/opnsense-controller 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/opnsense-controller/result/bin/opnsense-controller /home/tappaas/bin/opnsense-controller
rm /home/tappaas/bin/zone-manager 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/opnsense-controller/result/bin/zone-manager /home/tappaas/bin/zone-manager
# TODO check if credentials file exist and if not write the example file and give warning
# For now just set the permissions
# cp credentials.example.txt ~/.opnsense-credentials.txt
chmod 600 ~/.opnsense-credentials.txt
echo -e "\nopnsense-controller binary installed to /home/tappaas/bin/opnsense-controller"
echo -e "Copying the AssignSettingsController.php to the OPNsense controller node..."
cd ..
scp opnsense-patch/AssignSettingsController.php root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignSettingsController.php

# Build the update-tappaas project
echo -en "\nBuilding the update-tappaas project"
cd update-tappaas
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/update-tappaas-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/update-tappaas 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update-tappaas/result/bin/update-tappaas /home/tappaas/bin/update-tappaas
rm /home/tappaas/bin/update-node 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update-tappaas/result/bin/update-node /home/tappaas/bin/update-node
echo -e "\nupdate-tappaas and update-node binaries installed to /home/tappaas/bin/"
/home/tappaas/bin/update-cron.sh
echo -e "\nupdate-tappaas cron job updated."
cd ..

# Update the configuration.json, zones.json and tappaas-cicd.json if there are changes
echo -e "\nChecking for updates to configuration.json..."
cd ..
if update-json.sh configuration ; then
    echo "configuration.json updated"
fi
echo -e "\nChecking for updates to zones.json..."
if update-json.sh zones ; then
    echo "zones.json updated"
fi
echo "Applying zone configuration..."
# always re-run zones update in case firewall logic is changed
/home/tappaas/bin/zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute
echo -e "\nChecking for updates to tappaas.json..."
cd 30-tappaas-cicd
if update-json.sh tappaas-cicd; then
    echo "tappaas-cicd.json updated, applying configuration..."
    # TODO
fi

# Update HA configuration (creates/updates/removes based on HANode field)
/home/tappaas/bin/update-HA.sh tappaas-cicd

# rebuild the nixos configuration
nixos-rebuild --target-host "tappaas@${VMNAME}.${ZONE0NAME}.internal" --use-remote-sudo switch -I "nixos-config=./${VMNAME}.nix"

echo -e "\nVM update completed successfully."