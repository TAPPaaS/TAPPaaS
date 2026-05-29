#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Delete (issue #45).
#
# Reverses install-service.sh:
#   • Authentik: detach the Proxy provider from the embedded outpost and
#     delete the Application + Provider for this module.
#   • Caddy handler ForwardAuth is left alone — firewall:proxy/delete-service.sh
#     deletes the whole reverse + handler when the consumer goes away, so
#     turning ForwardAuth off here would just churn config that's about to be
#     removed anyway.
#
# Idempotent (safe to re-run / safe if module already gone).
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <module-name>"

if ! command -v authentik-manager >/dev/null 2>&1; then
    warn "authentik-manager not in PATH — skipping Authentik teardown for ${MODULE}"
    exit 0
fi
if [[ ! -f "${HOME}/.authentik-credentials.txt" ]]; then
    warn "${HOME}/.authentik-credentials.txt missing — skipping Authentik teardown for ${MODULE}"
    exit 0
fi

info "identity:accessControl: tearing down Authentik wiring for ${MODULE}"
authentik-manager app-delete "${MODULE}" || warn "  app-delete for ${MODULE} returned non-zero (may already be gone)"
info "  ${GN}✓${CL} Authentik app/provider for ${MODULE} removed"
