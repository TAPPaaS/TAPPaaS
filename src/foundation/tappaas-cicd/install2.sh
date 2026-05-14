#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# Minimal logging before common-install-routines.sh is available
_info()  { echo -e "\033[32m[Info]\033[m $*"; }
_warn()  { echo -e "\033[33m[Warning]\033[m $*"; }
_error() { echo -e "\033[01;31m[Error]\033[m $*" >&2; }

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  _error "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

#
# Bootstrap default: use tappaas1 as the primary node for initial cluster discovery.
# Once configuration.json exists, scripts use get_primary_node_fqdn() instead.
# For legacy systems with different hostnames, pass --primary-node to create-configuration.sh.
MGMTVLAN="mgmt"
NODE1_FQDN="${TAPPAAS_PRIMARY_NODE:-tappaas1}.$MGMTVLAN.internal"
export FIREWALL_FQDN="firewall.$MGMTVLAN.internal"  # Used by sourced scripts

# Accept SSH host keys on first connection (but still reject changed keys)
SSH_ACCEPT="-o StrictHostKeyChecking=accept-new"

# copy the public keys to the root account of every proxmox host
echo ""
_info "Installing SSH keys on Proxmox nodes..."
while read -r node; do
  NODE_FQDN="$node.$MGMTVLAN.internal"
  printf "  %s " "$node"
  ssh-copy-id $SSH_ACCEPT -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" < /dev/null 2>&1 | while IFS= read -r _; do printf "."; done || echo " (failed or already installed)"
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh -n $SSH_ACCEPT root@"$NODE_FQDN" "mkdir -p /root/tappaas" 2>/dev/null
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub < /dev/null 2>/dev/null
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key < /dev/null 2>/dev/null
  echo " done"
done < <(ssh -n $SSH_ACCEPT root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

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
        _info "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done

# create the configuration.json
if [ -f ./scripts/create-configuration.sh ]; then
  . ./scripts/create-configuration.sh
else
  _error "./scripts/create-configuration.sh not found"
  exit 1
fi

# Use zones.json from the TAPPaaS repo — it is the canonical source of truth.
# Previously this was copied from the Proxmox node, which caused the repo version
# to be silently overwritten on every install2.sh run.
cp /home/tappaas/TAPPaaS/src/foundation/firewall/zones.json /home/tappaas/config/zones.json

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
echo ""
_info "Installing scripts to /home/tappaas/bin/..."
cd
cd TAPPaaS || { _error "TAPPaaS directory not found!"; exit 1; }
# get to the right directory
cd src/foundation/tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
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
cd ../cluster || { _error "Cluster directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh cluster
cd ../templates || { _error "Templates directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh templates
cd ../firewall || { _error "Firewall directory not found!"; exit 1; }
FIREWALL_AVAILABLE=true
if ! ping -c 1 -W 2 "$FIREWALL_FQDN" >/dev/null 2>&1; then
    FIREWALL_AVAILABLE=false
    echo ""
    _warn "OPNsense firewall ($FIREWALL_FQDN) is not reachable."
    _warn "Deploying firewall module with firewallType=NONE."
    _warn "You will need to configure reverse proxy and firewall rules manually."
fi
/home/tappaas/bin/copy-update-json.sh firewall
if [[ "$FIREWALL_AVAILABLE" == "false" ]]; then
    # Override: remove VM dependencies and mark as non-OPNsense deployment
    tmp_fw=$(mktemp)
    jq '.dependsOn = [] | .firewallType = "NONE"' /home/tappaas/config/firewall.json > "$tmp_fw" \
        && mv "$tmp_fw" /home/tappaas/config/firewall.json
fi
cd ../tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh tappaas-cicd

# run the full tappaas-cicd update scripts with all dependencies and checks
/home/tappaas/bin/update-module.sh tappaas-cicd --no-snapshot
/home/tappaas/bin/update-module.sh cluster

# Source common-install-routines.sh to replace the minimal _info/_warn/_error with full versions
. /home/tappaas/bin/common-install-routines.sh

if [[ "$FIREWALL_AVAILABLE" == "true" ]]; then
    # Install and enable QEMU guest agent on OPNsense (FreeBSD)
    # This allows Proxmox to communicate with the firewall VM via the guest agent
    echo ""
    info "Installing QEMU guest agent on OPNsense..."
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info os-qemu-guest-agent'" &>/dev/null; then
        info "  QEMU guest agent already installed"
    else
        ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y os-qemu-guest-agent'" || {
            warn "QEMU guest agent installation failed. Install manually via OPNsense UI."
        }
    fi
    info "Enabling QEMU guest agent service..."
    ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'sysrc qemu_guest_agent_enable=YES'" 2>/dev/null || true
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent status'" &>/dev/null; then
        info "  QEMU guest agent service is already running"
    else
        ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent start'" 2>/dev/null || {
            warn "QEMU guest agent service could not be started. Enable manually in OPNsense."
        }
    fi

    # Update the firewall module
    /home/tappaas/bin/update-module.sh firewall --no-snapshot

    # Setup Caddy reverse proxy on the firewall
    # (needs to be after update.sh as it relies on opnsense-controller to be installed)
    echo ""
    info "Setting up Caddy reverse proxy..."
    chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh
    /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh || {
        warn "Caddy setup encountered issues. Please review and complete manually."
    }
else
    echo ""
    warn "Skipping firewall update (no OPNsense firewall)."
    warn "Skipping Caddy reverse proxy setup (no OPNsense firewall)."
    warn "When modules with firewall:proxy dependency are installed,"
    warn "you will see manual configuration instructions for your firewall."
fi

echo ""
info "${GN}✓${CL} TAPPaaS-CICD installation completed successfully."
