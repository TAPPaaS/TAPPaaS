#!/usr/bin/env bash
# TAPPaaS Module: woodpecker — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# before this runs; forgejo:oauth has written the Forgejo client. This waits for
# the server and the agent, and says where Woodpecker is.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-woodpecker}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${HOST}" "$@"; }

echo ""
info "${BOLD}woodpecker: waiting for the server and its agent on ${HOST}${CL}"
if [[ "$(vm "sudo test -s /etc/secrets/forgejo-oauth.env && echo yes" 2>/dev/null)" != "yes" ]]; then
    warn "  no Forgejo client (/etc/secrets/forgejo-oauth.env) — forgejo:oauth has not run; the server starts once it has"
    exit 0
fi
# The client may have been written moments ago: bring both units to it.
vm "sudo systemctl restart woodpecker-env.service woodpecker-egress.service; sudo systemctl is-active -q woodpecker-server || sudo systemctl restart woodpecker-server woodpecker-agent-docker" >/dev/null 2>&1 || true
for _i in $(seq 1 36); do
    vm "curl -sf --max-time 5 -o /dev/null http://localhost:8000/healthz && curl -sf --max-time 5 -o /dev/null http://127.0.0.1:3000/healthz" 2>/dev/null && break
    [[ ${_i} -eq 36 ]] && { warn "  Woodpecker or its agent did not answer within 3 minutes — journalctl -u woodpecker-server -u woodpecker-agent-docker on the VM"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} the server and its agent answer"

URL="$(vm "systemctl show -p Environment --value woodpecker-server | tr ' ' '\n' | sed -n 's/^WOODPECKER_HOST=//p'" 2>/dev/null || true)"
echo ""
info "${BOLD}Update complete${CL}"
info "  Open ${URL:-http://${HOST}:8000} — Login with Forgejo"
