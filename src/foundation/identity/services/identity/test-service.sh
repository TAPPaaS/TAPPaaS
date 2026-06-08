#!/usr/bin/env bash
#
# TAPPaaS Identity Service - Test (ADR-006 Phase 4, issue #56).
#
# Verifies the OIDC (identity:identity) wiring for a consuming module:
#   1. an OIDC Application with the module's slug exists in Authentik;
#   2. that Application has at least one access PolicyBinding (the gate — an
#      unbound app is allow-all, which would defeat variant isolation).
# Called by test-module.sh for any module that depends on identity:identity.
#
# Usage: test-service.sh <effective-module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <effective-module-name>"; exit 2; }

info "  ${BOLD}identity:identity tests for ${BL}${MODULE}${CL}"

if ! ${AUTHENTIK_MANAGER} test >/dev/null 2>&1; then
    error "  authentik-manager cannot reach Authentik"
    exit 2
fi

CREDS="${HOME}/.authentik-credentials.txt"
URL="$(grep '^url=' "${CREDS}" | cut -d= -f2-)"
TOKEN="$(grep '^token=' "${CREDS}" | cut -d= -f2-)"
api() { curl -fsS -H "Authorization: Bearer ${TOKEN}" "${URL}/api/v3$1"; }

fail=0

# 1. Application exists (superuser_full_list — a bound app is hidden otherwise).
APP_PK="$(api "/core/applications/?superuser_full_list=true&page_size=1000" \
    | jq -r --arg s "${MODULE}" '.results[] | select(.slug==$s) | .pk')"
if [[ -n "${APP_PK}" ]]; then
    info "    ${GN}✓${CL} OIDC application '${MODULE}' present"
else
    error "    ✗ no OIDC application with slug '${MODULE}'"
    fail=1
fi

# 2. Access binding present (the gate).
if [[ -n "${APP_PK}" ]]; then
    n="$(api "/policies/bindings/?page_size=1000" \
        | jq -r --arg t "${APP_PK}" '[.results[] | select(.target==$t)] | length')"
    if [[ "${n:-0}" -ge 1 ]]; then
        info "    ${GN}✓${CL} access binding present (${n} group binding(s))"
    else
        error "    ✗ application '${MODULE}' has NO access binding (allow-all — variant isolation broken)"
        fail=1
    fi
fi

exit "${fail}"
