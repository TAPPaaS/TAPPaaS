#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

#
# creatae a fully qualified node hostname for tappaas1
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"
export FIREWALL_FQDN="firewall.$MGMTVLAN.internal"  # Used by sourced scripts

# copy the public keys to the root account of every proxmox host
while read -r node; do
  echo -e "\nInstalling SSH public key on proxmox node: $node"
  NODE_FQDN="$node.$MGMTVLAN.internal"
  ssh-copy-id -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" < /dev/null || echo "SSH key copy to $node failed or key already installed."
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh -n root@"$NODE_FQDN" "mkdir -p /root/tappaas"
  scp /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub < /dev/null
  scp /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key < /dev/null
done < <(ssh -n root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

# create tappaas binary director and config directory
mkdir -p /home/tappaas/config
mkdir -p /home/tappaas/bin

# Add /home/tappaas/bin to PATH
# On NixOS, .profile is sourced for login shells, and we also add to .bashrc
# for interactive non-login shells that explicitly source it
TAPPAAS_PATH_EXPORT='export PATH="/home/tappaas/bin:$PATH"'

# Export PATH for the current script execution
export PATH="/home/tappaas/bin:$PATH"

for rcfile in /home/tappaas/.profile /home/tappaas/.bashrc; do
    if ! grep -q '/home/tappaas/bin' "$rcfile" 2>/dev/null; then
        echo -e '\n# TAPPaaS bin directory' >> "$rcfile"
        echo "$TAPPAAS_PATH_EXPORT" >> "$rcfile"
        echo "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done

# create the configuration.json
if [ -f ./scripts/create-configuration.sh ]; then
  . ./scripts/create-configuration.sh
else
  echo "Error: ./scripts/create-configuration.sh not found"
  exit 1
fi 

# copy the potentially modified configuration.json and zones.json files from tappaas1 (potentially modified during bootstrap)
# Only copy specific files — avoid pulling unrelated JSONs (e.g., module-fields.json)
scp root@"$NODE1_FQDN":/root/tappaas/configuration.json /home/tappaas/config/ 2>/dev/null || true
scp root@"$NODE1_FQDN":/root/tappaas/zones.json /home/tappaas/config/ 2>/dev/null || true

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
echo -e "\nInstalling scripts to /home/tappaas/bin/..."
cd
cd TAPPaaS || { echo "TAPPaaS directory not found!"; exit 1; }
# get to the right directory
cd src/foundation/tappaas-cicd || { echo "TAPPaaS-CICD directory not found!"; exit 1; }
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
# chmod only real files/valid symlinks, skip dangling symlinks
for f in /home/tappaas/bin/*.sh; do
  [ -e "$f" ] && chmod +x "$f"
done

# Install the cluster and firewall jsons
cd ../cluster || { echo "Cluster directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh cluster
cd ../templates || { echo "Templates directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh templates
cd ../firewall || { echo "Firewall directory not found!"; exit 1; }
FIREWALL_AVAILABLE=true
if ! ping -c 1 -W 2 "$FIREWALL_FQDN" >/dev/null 2>&1; then
    FIREWALL_AVAILABLE=false
    echo -e "\n\033[33m[WARN]\033[m OPNsense firewall ($FIREWALL_FQDN) is not reachable."
    echo -e "\033[33m[WARN]\033[m Deploying firewall module with firewallType=NONE."
    echo -e "\033[33m[WARN]\033[m You will need to configure reverse proxy and firewall rules manually.\n"
fi
/home/tappaas/bin/copy-update-json.sh firewall
if [[ "$FIREWALL_AVAILABLE" == "false" ]]; then
    # Override: remove VM dependencies and mark as non-OPNsense deployment
    tmp_fw=$(mktemp)
    jq '.dependsOn = [] | .firewallType = "NONE"' /home/tappaas/config/firewall.json > "$tmp_fw" \
        && mv "$tmp_fw" /home/tappaas/config/firewall.json
fi
cd ../tappaas-cicd || { echo "TAPPaaS-CICD directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh tappaas-cicd

# run the full tappaas-cicd update scripts with all dependencies and checks
/home/tappaas/bin/update-module.sh tappaas-cicd
/home/tappaas/bin/update-module.sh cluster
/home/tappaas/bin/update-module.sh firewall

if [[ "$FIREWALL_AVAILABLE" == "true" ]]; then
    # Setup Caddy reverse proxy on the firewall
    # (needs to be after update.sh as it relies on opnsense-controller to be installed)
    echo -e "\nSetting up Caddy reverse proxy..."
    chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh
    /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh || {
        echo "Warning: Caddy setup encountered issues. Please review and complete manually."
    }
else
    echo -e "\n\033[33m[WARN]\033[m Skipping Caddy reverse proxy setup (no OPNsense firewall)."
    echo -e "\033[33m[WARN]\033[m When modules with firewall:proxy dependency are installed,"
    echo -e "\033[33m[WARN]\033[m you will see manual configuration instructions for your firewall.\n"
fi

echo -e "\nTAPPaaS-CICD installation completed successfully."
