#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# rebuild the nixos configuration
info "  Rebuilding NixOS configuration..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    sudo nixos-rebuild switch -I "nixos-config=./${VMNAME}.nix"
else
    sudo nixos-rebuild switch -I "nixos-config=./${VMNAME}.nix" 2>&1 | while IFS= read -r _; do printf "."; done
    echo ""
fi

info "  Updating cron job..."
/home/tappaas/bin/update-cron.sh

info "  ${GN}✓${CL} VM update completed successfully"
