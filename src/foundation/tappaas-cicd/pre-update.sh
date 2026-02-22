#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -e

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
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
cd src/foundation/tappaas-cicd || { echo "TAPPaaS-CICD directory not found!"; exit 1; }

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
echo -e "\nInstalling scripts to /home/tappaas/bin/..."
for script in scripts/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="/home/tappaas/bin/$script_name"
    # Remove existing file or symlink if it exists
    rm -f "$target" 2>/dev/null || true
    # Create symlink to the script in the repo
    ln -s "$(realpath "$script")" "$target"
  fi
done
chmod +x /home/tappaas/bin/*.sh

# --- Symlink foundation config files into /home/tappaas/config/ ---
for config_file in ../module-fields.json ../zones.json; do
  if [ -f "$config_file" ]; then
    config_name=$(basename "$config_file")
    target="/home/tappaas/config/$config_name"
    rm -f "$target" 2>/dev/null || true
    ln -s "$(realpath "$config_file")" "$target"
  fi
done

# --- Build and install opnsense-controller ---
echo -en "\nBuilding the opnsense-controller project"
cd opnsense-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/opnsense-controller-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/opnsense-controller 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/opnsense-controller /home/tappaas/bin/opnsense-controller
rm /home/tappaas/bin/zone-manager 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/zone-manager /home/tappaas/bin/zone-manager
rm /home/tappaas/bin/dns-manager 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/dns-manager /home/tappaas/bin/dns-manager
# Ensure OPNsense credentials file exists; if missing, create a skeleton and warn
if [ ! -f ~/.opnsense-credentials.txt ]; then
  echo "Warning: ~/.opnsense-credentials.txt not found; creating skeleton file with empty key/secret. Please populate it with real values."
  cat > ~/.opnsense-credentials.txt <<'EOF'
key=
secret=
EOF
fi
chmod 600 ~/.opnsense-credentials.txt
echo -e "\nopnsense-controller binary installed to /home/tappaas/bin/opnsense-controller"
cd ..

# --- Build and install update-tappaas ---
echo -en "\nBuilding the update-tappaas project"
cd update-tappaas
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/update-tappaas-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/update-tappaas 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update-tappaas/result/bin/update-tappaas /home/tappaas/bin/update-tappaas
rm /home/tappaas/bin/update-node 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update-tappaas/result/bin/update-node /home/tappaas/bin/update-node
echo -e "\nupdate-tappaas and update-node binaries installed to /home/tappaas/bin/"
cd ..

# --- Copy OPNsense controller patch to the firewall ---
echo -e "Copying the AssignSettingsController.php to the OPNsense controller node..."
if ping -c 1 -W 1 "$FIREWALL_FQDN" >/dev/null 2>&1; then
  echo "Firewall $FIREWALL_FQDN reachable; will attempt to copy controller patch."
  scp opnsense-patch/InterfaceAssignController.php root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/InterfaceAssignController.php
  scp opnsense-patch/ACL.xml root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/ACL.xml
  echo "OPNsense controller patch (InterfaceAssignController.php) and ACL file copied to firewall."
else
  echo "Warning: Firewall $FIREWALL_FQDN appears unreachable; skipping controller patch copy."
fi

echo -e "\nAll TAPPaaS-CICD programs and scripts installed successfully."
