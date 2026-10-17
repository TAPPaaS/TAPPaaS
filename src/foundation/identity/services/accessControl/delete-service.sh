#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Delete (issue #45).
#
# Reverses install-service.sh:
#   • Authentik: detach the Proxy provider from the embedded outpost and
#     delete the Application + Provider for this module.
#   • Caddy: when the module is being DELETED, ForwardAuth is left alone —
#     network:proxy/delete-service.sh removes the whole route, and turning the
#     gate off first would open the app until it does. When only the gate goes
#     and the route stays (identity:accessControl dropped from dependsOn while
#     network:proxy remains, ADR-032 D3), the route's handles get ForwardAuth
#     off: the outpost no longer has a provider for the host, so a gated handle
#     would answer every request with an error.
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

# ── The route stays: turn its gate off ─────────────────────────────────────
# The update's dependsOn delta runs this after the config has dropped
# identity:accessControl; a module delete runs it with the config unchanged.
_DEPS="$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json" 2>/dev/null | jq -c '.dependsOn // []' 2>/dev/null || echo '[]')"
if jq -e 'index("network:proxy") != null and index("identity:accessControl") == null' <<<"${_DEPS}" >/dev/null 2>&1; then
    # The catch-all ("TAPPaaS: <module>") and its path handles ("TAPPaaS: <module> <path>");
    # each also gives back the caller's Authorization header (caddy-manager set-gate).
    _out="$(caddy-manager set-gate --off --description-prefix "TAPPaaS: ${MODULE}" --no-ssl-verify)" \
        || die "Failed to turn forward-auth off on the handles of ${MODULE}"
    info "  ${GN}✓${CL} ${MODULE} keeps its route without the Authentik gate (${_out##*off on })"
fi
