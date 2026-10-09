#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Test (#752, #805).
#
# Verifies the forward-auth (identity:accessControl) wiring for a consumer:
#   1. Authentik has a Proxy Application with the module's slug, and its
#      provider is attached to the embedded outpost;
#   2. that Application has at least one group binding (the gate — an unbound
#      app lets every Authentik user through, ADR-006 §5);
#   3. the module's Caddy handler ("TAPPaaS: <module>") has ForwardAuth on;
#   4. an unauthenticated request to the public URL gets Authentik, not the app.
# Called by test-module.sh for any module that depends on identity:accessControl.
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

_ACCESSCONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/oidc-consumer.sh disable=SC1091
. "${_ACCESSCONTROL_DIR}/../../lib/oidc-consumer.sh"
AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 2; }

info "  ${BOLD}identity:accessControl tests for ${BL}${MODULE}${CL}"

# Same verdict as install-service.sh, from the same predicate: a module the site
# publishes nowhere has no route, so there is no gate to verify.
_TS_JSON="$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json" 2>/dev/null || echo '{}')"
DOMAIN="$(oidc_public_domain \
    "$(jq -r '.vmname // empty' <<<"${_TS_JSON}")" \
    "$(jq -r '.environment // ""' <<<"${_TS_JSON}")" "${_TS_JSON}")"
if [[ -z "${DOMAIN}" ]]; then
    info "    ${GN}✓${CL} not published (no domain for environment '$(jq -r '.environment // "default"' <<<"${_TS_JSON}")') — no forward-auth to verify"
    exit 0
fi
if oidc_domain_unpublished "${DOMAIN}"; then
    info "    ${GN}✓${CL} not published (${DOMAIN} has no public DNS record) — no forward-auth to verify"
    exit 0
fi
GATE_SLUG="$(accesscontrol_gate_slug "${MODULE}" "${_TS_JSON}")"

if ! ${AUTHENTIK_MANAGER} test >/dev/null 2>&1; then
    error "  authentik-manager cannot reach Authentik"
    exit 2
fi
CREDS="${HOME}/.authentik-credentials.txt"
URL="$(grep '^url=' "${CREDS}" | cut -d= -f2-)"
TOKEN="$(grep '^token=' "${CREDS}" | cut -d= -f2-)"
# The token goes in on stdin, not argv, so `ps` never shows it.
api() { curl -fsS -H @- "${URL}/api/v3$1" <<<"Authorization: Bearer ${TOKEN}"; }

fail=0

# 1. Application + provider on the embedded outpost (superuser_full_list — a
#    bound app is hidden from the list otherwise).
APPS="$(api "/core/applications/?superuser_full_list=true&page_size=1000" || echo '{}')"
APP_PK="$(jq -r --arg s "${GATE_SLUG}" '.results[]? | select(.slug==$s) | .pk' <<<"${APPS}")"
PROV_PK="$(jq -r --arg s "${GATE_SLUG}" '.results[]? | select(.slug==$s) | .provider // empty' <<<"${APPS}")"
if [[ -n "${APP_PK}" && -n "${PROV_PK}" ]]; then
    info "    ${GN}✓${CL} proxy application '${GATE_SLUG}' present"
    attached="$( (api "/outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded" || echo '{}') \
        | jq -r --argjson p "${PROV_PK}" '[.results[]? | select(.providers | index($p))] | length')"
    if [[ "${attached:-0}" -ge 1 ]]; then
        info "    ${GN}✓${CL} provider attached to the embedded outpost"
    else
        error "    ✗ provider of '${GATE_SLUG}' is not on the embedded outpost — the gate cannot answer"
        fail=1
    fi
else
    error "    ✗ no proxy application with slug '${GATE_SLUG}'"
    fail=1
fi

# 2. Access binding present (the gate).
if [[ -n "${APP_PK}" ]]; then
    n="$(api "/policies/bindings/?page_size=1000" \
        | jq -r --arg t "${APP_PK}" '[.results[] | select(.target==$t)] | length')"
    if [[ "${n:-0}" -ge 1 ]]; then
        info "    ${GN}✓${CL} access binding present (${n} group binding(s))"
    else
        error "    ✗ application '${GATE_SLUG}' has NO access binding — every Authentik user passes"
        fail=1
    fi
fi

# 3. ForwardAuth on the module's Caddy handler.
OPNSENSE_CREDS="${HOME}/.opnsense-credentials.txt"
if [[ -f "${OPNSENSE_CREDS}" ]]; then
    _auth="$(grep '^key=' "${OPNSENSE_CREDS}" | cut -d= -f2-):$(grep '^secret=' "${OPNSENSE_CREDS}" | cut -d= -f2-)"
    fa="$(curl -ksS -K - "https://firewall.mgmt.internal:8443/api/caddy/ReverseProxy/searchHandle" <<<"user = \"${_auth}\"" 2>/dev/null \
        | jq -r --arg d "TAPPaaS: ${MODULE}" '[.rows[]? | select(.description==$d) | .ForwardAuth] | join(",")' 2>/dev/null)" || fa=""
    case "${fa}" in
        1)  info "    ${GN}✓${CL} Caddy handler has ForwardAuth on" ;;
        "") error "    ✗ no Caddy handler 'TAPPaaS: ${MODULE}' found"; fail=1 ;;
        *)  error "    ✗ Caddy handler 'TAPPaaS: ${MODULE}' has ForwardAuth=${fa} — requests reach the app ungated"; fail=1 ;;
    esac
else
    warn "    ⚠ Caddy handler NOT verified — ${OPNSENSE_CREDS} missing"
fi

# 4. What an anonymous caller actually gets. Followed redirects end at
#    Authentik's flow page when the gate works; anything else served is a leak.
#    A zone filter (proxyAllowedZones) that refuses cicd's own zone answers 403
#    before the gate — that hides the gate from here, it does not fail it.
tmp="$(mktemp)"
code="$(curl -ksSL --max-redirs 8 -o "${tmp}" -w '%{http_code}' --max-time 20 "https://${DOMAIN}/" 2>/dev/null)" || code=000
[[ -n "${code}" ]] || code=000
if grep -qi "authentik" "${tmp}"; then
    info "    ${GN}✓${CL} anonymous request to https://${DOMAIN}/ gets the Authentik login (http ${code})"
elif [[ "${code}" == "403" ]]; then
    warn "    ⚠ gate NOT observed — https://${DOMAIN}/ refuses this host's zone (403, proxyAllowedZones)"
elif [[ "${code}" == "000" ]]; then
    warn "    ⚠ gate NOT observed — https://${DOMAIN}/ did not answer"
else
    error "    ✗ anonymous request to https://${DOMAIN}/ was served without Authentik (http ${code}, $(wc -c < "${tmp}") bytes)"
    fail=1
fi
rm -f "${tmp}"

exit "${fail}"
