#!/usr/bin/env bash
#
# forgejo — update
#
# Checks that Forgejo answers after templates:nixos has applied forgejo.nix
# (see below: the OS build is not done here).
# Safe to re-run — NixOS rebuilds are idempotent.
#
# Usage: update.sh <vmname>
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-forgejo}"


VMNAME="$(get_config_value 'vmname' "${1:-forgejo}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvWork')"
VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

echo ""
info "${BOLD}Forgejo — update${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
info "  Host: ${VM_HOST}"

# The NixOS configuration (forgejo.nix) is NOT applied here: the templates:nixos
# dependency (update-os.sh) builds and applies it on every install and update,
# against the release's pinned nixpkgs, release moves staged for the next boot
# (#728), built on the mothership (#774). A rebuild here would build again
# against the VM's own channel and could undo a release move.

# ── Verify Forgejo is responding ───────────────────────────────────────────
info "Verifying Forgejo service on port 3000…"
RETRY=0
until ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -sf http://localhost:3000 > /dev/null 2>&1" 2>/dev/null; do
    RETRY=$((RETRY + 5))
    if [[ ${RETRY} -ge 60 ]]; then
        warn "Forgejo not responding on port 3000 after 60s — check logs: journalctl -u forgejo"
        break
    fi
    sleep 5
done
[[ ${RETRY} -lt 60 ]] && info "  Forgejo responding on port 3000 — OK"

echo ""
info "${BOLD}Update complete${CL}"
info "  VM: ${VMNAME}  Node: ${NODE}  Zone: ${ZONE0NAME}"
