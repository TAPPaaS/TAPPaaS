#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# rebuild the nixos configuration
info "  Rebuilding NixOS configuration..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    sudo nixos-rebuild switch -I "nixos-config=./${VMNAME}.nix" || die "nixos-rebuild failed"
else
    # Pipe to dots but preserve nixos-rebuild's real exit code via PIPESTATUS —
    # a bare `cmd | while read` reports the while-loop's status, masking a
    # failed rebuild (issue #201). set +e keeps the pipe from aborting first.
    set +e
    sudo nixos-rebuild switch -I "nixos-config=./${VMNAME}.nix" 2>&1 | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    [[ "${rc}" -eq 0 ]] || die "nixos-rebuild failed (exit ${rc})"
fi

info "  Updating cron job..."
/home/tappaas/bin/update-cron.sh

info "  ${GN}✓${CL} VM update completed successfully"
