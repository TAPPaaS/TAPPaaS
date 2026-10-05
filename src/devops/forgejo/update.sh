#!/usr/bin/env bash
#
# forgejo — update
#
# Copies forgejo.nix to the VM as /etc/nixos/forgejo.nix — where
# templates:nixos (update-os.sh) deploys it, beside the TAPPaaS baseline it
# imports (#324) — then runs nixos-rebuild switch with it.
# Safe to re-run — NixOS rebuilds are idempotent.
#
# Usage: update.sh <vmname>
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-forgejo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── 1. Wait for VM to be reachable ────────────────────────────────────────────
info "Waiting for SSH on ${VM_HOST}…"
WAIT=0
until ssh ${SSH_OPTS} "tappaas@${VM_HOST}" true 2>/dev/null; do
    WAIT=$((WAIT + 5))
    if [[ ${WAIT} -ge 120 ]]; then
        error "Timeout: VM ${VM_HOST} not reachable after 120s"
        exit 1
    fi
    sleep 5
done
info "  SSH reachable — OK"

# ── 2. Deploy NixOS configuration ─────────────────────────────────────────────
info "Copying forgejo.nix to ${VM_HOST}…"
scp ${SSH_OPTS} "${SCRIPT_DIR}/forgejo.nix" \
    "tappaas@${VM_HOST}:/tmp/forgejo.nix"

info "Installing configuration…"
# shellcheck disable=SC2029
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "
    set -euo pipefail
    sudo install -m 0644 /tmp/forgejo.nix /etc/nixos/forgejo.nix && rm -f /tmp/forgejo.nix
    sudo nixos-rebuild switch -I nixos-config=/etc/nixos/forgejo.nix 2>&1
"
info "  NixOS rebuild — OK"

# ── 3. Verify Forgejo is responding ───────────────────────────────────────────
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
