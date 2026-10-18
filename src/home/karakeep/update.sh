#!/usr/bin/env bash
# TAPPaaS Module: karakeep — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# on every install and update, before this runs: it brings the stack to the
# pinned images and assembles its environment (sign-in, AI tagging). This waits
# for Karakeep to answer and says where it is.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-karakeep}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${HOST}" "$@"; }

echo ""
info "${BOLD}karakeep: waiting for the web app on ${HOST}${CL}"
for _i in $(seq 1 60); do
    vm "curl -sf --max-time 5 http://localhost:3000/api/health >/dev/null" 2>/dev/null && break
    [[ ${_i} -eq 60 ]] && { warn "  Karakeep did not answer within 5 minutes — see journalctl -u karakeep on the VM"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} Karakeep answers"

URL="$(vm "sudo sed -n 's/^NEXTAUTH_URL=//p' /run/karakeep/env" 2>/dev/null || true)"
echo ""
info "${BOLD}Update complete${CL}"
info "  Open ${URL:-http://${HOST}:3000} — Sign in with Authentik"
