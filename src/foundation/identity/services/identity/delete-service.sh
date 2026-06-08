#!/usr/bin/env bash
#
# TAPPaaS Identity Service — Delete (ADR-006 Phase 4, issue #56).
#
# Reverses install-service.sh for an OIDC (identity:identity) consumer:
#   • Authentik: delete the OIDC Application + OAuth2 Provider for this module
#     (app-delete handles both proxy and oauth2 providers; its policy bindings
#     cascade with the Application).
#
# The module's role groups (<scope>-users / -admins / -<module>-admins) are
# LEFT in place — they may still hold members and other apps may use them;
# removing role groups is an operator decision, not a side-effect of deleting
# one module. The VM's /etc/secrets/<base>.env goes away with the VM itself.
#
# Idempotent (safe to re-run / safe if the app is already gone).
#
# Usage: delete-service.sh <effective-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <effective-module-name>"

if ! command -v "${AUTHENTIK_MANAGER%% *}" >/dev/null 2>&1 && [[ ! -x "${AUTHENTIK_MANAGER}" ]]; then
    warn "authentik-manager not in PATH — skipping Authentik teardown for ${MODULE}"
    exit 0
fi
if [[ ! -f "${HOME}/.authentik-credentials.txt" ]]; then
    warn "${HOME}/.authentik-credentials.txt missing — skipping Authentik teardown for ${MODULE}"
    exit 0
fi

info "identity:identity (OIDC): tearing down Authentik wiring for ${MODULE}"
${AUTHENTIK_MANAGER} app-delete "${MODULE}" \
    || warn "  app-delete for ${MODULE} returned non-zero (may already be gone)"
info "  ${GN}✓${CL} Authentik OIDC app/provider for ${MODULE} removed (role groups left intact)"
