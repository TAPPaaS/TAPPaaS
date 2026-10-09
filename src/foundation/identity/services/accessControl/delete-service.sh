#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Delete (issue #45).
#
# Reverses install-service.sh:
#   • Authentik: detach the Proxy provider from the embedded outpost and
#     delete the Application + Provider for this module.
#   • Caddy handler ForwardAuth is left alone — network:proxy/delete-service.sh
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

debug "identity:accessControl: tearing down Authentik wiring for ${MODULE}"
# The gate's slug, from the same predicate as install (#806): <module>-gate when
# the module's OIDC app holds <module> — deleting <module> here would remove
# that app instead. --only-proxy keeps it safe either way.
_DS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/oidc-consumer.sh disable=SC1091
. "${_DS_DIR}/../../lib/oidc-consumer.sh"
GATE_SLUG="$(accesscontrol_gate_slug "${MODULE}" \
    "$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json" 2>/dev/null || echo '{}')")"
authentik-manager app-delete "${GATE_SLUG}" --only-proxy \
    || warn "  app-delete for ${GATE_SLUG} returned non-zero (may already be gone)"
debug "  ${GN}✓${CL} Authentik app/provider ${GATE_SLUG} removed"
