#!/usr/bin/env bash
#
# TAPPaaS Identity Service - Test (ADR-006 Phase 4, issue #56).
#
# Verifies the OIDC (identity:identity) wiring for a consuming module:
#   1. an OIDC Application with the module's slug exists in Authentik;
#   2. that Application has at least one access PolicyBinding (the gate — an
#      unbound app is allow-all, which would defeat variant isolation);
#   3. the consumer VM holds the OIDC client config for THAT provider — the
#      secrets env carries OIDC_CLIENT_ID (matching Authentik), _SECRET and
#      _DISCOVERY_URI (#560: an app can exist while its consumer never got it);
#   4. the unit that registers the provider in the app has run successfully.
# Called by test-module.sh for any module that depends on identity:identity.
#
# Usage: test-service.sh <effective-module-name>
#
# Env:
#   TAPPAAS_TEST_OIDC_SECRETS_ENV  check this path on the VM instead of the
#                                  module's secrets env (#560 regression fixture)
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_IDENTITY_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/oidc-consumer.sh disable=SC1091
. "${_IDENTITY_SVC_DIR}/../../lib/oidc-consumer.sh"

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <effective-module-name>"; exit 2; }

info "  ${BOLD}identity:identity tests for ${BL}${MODULE}${CL}"

# Nothing to verify where nothing was registered. install-service.sh skips a
# module the site publishes nowhere — no public domain means no redirect URI,
# so no OIDC application exists — and this test must reach the same verdict
# from the same predicate. Until #698 it did not: it reported "no OIDC
# application with slug '<module>'" as drift, which made `reconcile --apply`
# declare the module unconverged and roll the update back. Checked before
# Authentik is contacted at all: an unpublished module has no business failing
# on a provider it never used.
_TS_JSON="$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json" 2>/dev/null || echo '{}')"
_TS_DOMAIN="$(oidc_public_domain \
    "$(jq -r '.vmname // empty' <<<"${_TS_JSON}")" \
    "$(jq -r '.environment // ""' <<<"${_TS_JSON}")" "${_TS_JSON}")"
if [[ -z "${_TS_DOMAIN}" ]]; then
    info "    ${GN}✓${CL} not published (no domain for environment '$(jq -r '.environment // "default"' <<<"${_TS_JSON}")') — no SSO to verify"
    exit 0
fi

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

# 1. Application exists (superuser_full_list — a bound app is hidden otherwise).
APPS="$(api "/core/applications/?superuser_full_list=true&page_size=1000" || echo '{}')"
APP_PK="$(jq -r --arg s "${MODULE}" '.results[]? | select(.slug==$s) | .pk' <<<"${APPS}")"
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

# 3–4. The consumer side: what install-service.sh writes onto the module VM.
MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
JSON="$(normalize_module_config < "${MODULE_JSON}" 2>/dev/null || echo '{}')"
VMNAME="$(jq -r '.vmname // empty' <<<"${JSON}")"
ZONE0="$(jq -r '.zone0 // empty' <<<"${JSON}")"
paths_ok=1
oidc_consumer_paths "${MODULE}" "$(jq -r '.environment // ""' <<<"${JSON}")" "${JSON}" || paths_ok=0
SECRETS_ENV="${TAPPAAS_TEST_OIDC_SECRETS_ENV:-${OIDC_SECRETS_ENV}}"
[[ "${SECRETS_ENV}" =~ ^/[A-Za-z0-9._/-]+$ ]] || paths_ok=0
UPSTREAM="${VMNAME}.${ZONE0}.internal"
vm() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "tappaas@${UPSTREAM}" "$@"; }

if [[ "${paths_ok}" -eq 0 ]]; then
    error "    ✗ identity.secretsEnv / identity.configureService is not a plain path / unit name — not checked"
    fail=1
elif [[ -z "${VMNAME}" || -z "${ZONE0}" ]]; then
    warn "    ⚠ consumer NOT verified — no vmname/zone0 for '${MODULE}'"
elif ! vm true 2>/dev/null; then
    warn "    ⚠ consumer NOT verified — ${UPSTREAM} not reachable over ssh"
else
    # client_id is public in OIDC; the secret is only tested for presence.
    want_id=""
    if [[ -n "${APP_PK}" ]]; then
        prov="$(jq -r --arg s "${MODULE}" '.results[]? | select(.slug==$s) | .provider // empty' <<<"${APPS}")"
        [[ -n "${prov}" ]] && want_id="$( (api "/providers/oauth2/${prov}/" || echo '{}') | jq -r '.client_id // empty')"
    fi
    keys="$(vm "sudo grep -o '^OIDC_[A-Z_]*=' $(printf %q "${SECRETS_ENV}") 2>/dev/null" || true)"
    have_id="$(vm "sudo sed -n 's/^OIDC_CLIENT_ID=//p' $(printf %q "${SECRETS_ENV}") 2>/dev/null" || true)"
    missing=""
    for k in OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DISCOVERY_URI; do
        grep -q "^${k}=" <<<"${keys}" || missing+=" ${k}"
    done
    if [[ -z "${keys}" ]]; then
        error "    ✗ consumer not wired: ${SECRETS_ENV} on ${VMNAME} holds no OIDC config ('module-manager reconcile ${MODULE} --apply' writes it)"
        fail=1
    elif [[ -n "${missing}" ]]; then
        error "    ✗ consumer half-wired: ${SECRETS_ENV} on ${VMNAME} lacks${missing}"
        fail=1
    elif [[ -n "${want_id}" && "${have_id}" != "${want_id}" ]]; then
        error "    ✗ consumer wired to a different provider: OIDC_CLIENT_ID in ${SECRETS_ENV} is not the Authentik client_id for '${MODULE}'"
        fail=1
    else
        info "    ${GN}✓${CL} consumer holds the OIDC client config (${SECRETS_ENV})"
    fi

    if [[ -z "${OIDC_CONFIGURE_SERVICE}" ]]; then
        info "    configureService=none — the app registers the provider itself (not checked here)"
    else
        unit="$(vm "systemctl show -p LoadState,Result,ExecMainStatus $(printf %q "${OIDC_CONFIGURE_SERVICE}")" 2>/dev/null || true)"
        if grep -q '^LoadState=not-found' <<<"${unit}"; then
            error "    ✗ ${OIDC_CONFIGURE_SERVICE} does not exist on ${VMNAME} — nothing registers the provider in the app"
            fail=1
        elif grep -q '^Result=success' <<<"${unit}" && grep -q '^ExecMainStatus=0' <<<"${unit}"; then
            info "    ${GN}✓${CL} ${OIDC_CONFIGURE_SERVICE} ran successfully"
        elif [[ -z "${unit}" ]]; then
            warn "    ⚠ ${OIDC_CONFIGURE_SERVICE} state NOT verified (systemctl did not answer)"
        else
            error "    ✗ ${OIDC_CONFIGURE_SERVICE} did not succeed on ${VMNAME}: $(tr '\n' ' ' <<<"${unit}")"
            fail=1
        fi
    fi
fi

exit "${fail}"
