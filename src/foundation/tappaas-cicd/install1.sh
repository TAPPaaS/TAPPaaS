#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# Helper functions for output
msg_info() {
  echo "INFO: $*"
}

msg_ok() {
  echo "OK: $*"
}

# Find the repo version of TAPPaaS to use
msg_info "Determining TAPPaaS repo to use"
if [ -z "${1:-}" ]; then
  REPOTOCLONE="https://github.com/TAPPaaS/TAPPaaS.git"
else
  REPOTOCLONE="$1"
fi
msg_ok "Determined TAPPaaS repo to use: ${REPOTOCLONE}"

# Find the branch version of TAPPaaS to use
msg_info "Determining TAPPaaS branch to use"
if [ -z "${2:-}" ]; then
  BRANCH="main"
else
  BRANCH="$2"
fi
msg_ok "Determined TAPPaaS branch to use: ${BRANCH}"

# clone the tappaas-cicd repo
echo -e "\nCloning TAPPaaS repository $REPOTOCLONE ..."
git clone "$REPOTOCLONE"
echo -e "\nswitching to branch $BRANCH..."
cd TAPPaaS || exit 1
git checkout "$BRANCH"

# go to the tappaas-cicd folder
echo -e "\nChanging to TAPPaaS-CICD directory and rebuilding the NixOS configuration..."
cd src/foundation/tappaas-cicd || exit 1

# rebuild the nixos configuration
sudo nixos-rebuild switch -I nixos-config=./tappaas-cicd.nix

# create ssh keys for the tappaas user
echo -e "\nCreating SSH keys for the tappaas user and installing them for the proxmox host..."
ssh-keygen -t ed25519 -f /home/tappaas/.ssh/id_ed25519 -N "" -C "tappaas-cicd"
# enforce secure permissions on the private key
sudo chown tappaas:users /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519
# add the public key to authorized_keys so that tappaas user can ssh to itself
cat /home/tappaas/.ssh/id_ed25519.pub >> /home/tappaas/.ssh/authorized_keys && chmod 600 /home/tappaas/.ssh/authorized_keys

chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/install1.sh
chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/install2.sh
chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update.sh

echo -e "\nPlease reboot tappaas-cicd VM."