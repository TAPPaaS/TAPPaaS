#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# rebuild the nixos configuration
info "  Rebuilding NixOS configuration..."
sudo nixos-rebuild switch -I "nixos-config=./${VMNAME}.nix"

info "  Updating cron job..."
/home/tappaas/bin/update-cron.sh

info "  ${GN}✓${CL} VM update completed successfully"
