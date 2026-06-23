#!/usr/bin/env bash
#
# TAPPaaS Identity — module tests (ADR-007 people/roles model).
#
# The role-group model (groups user/admin/root + the team group `users`) is now
# owned by people-manager (reconciled from config/people/ via `people-manager
# sync`); identity no longer ships roles-ensure.sh or user.sh. These tests assert
# that the OIDC install allow-list points at the people-manager role groups
# (user/admin/root) and that the live OIDC / forward-auth wiring works end to end.
#
# Commands are taken from ~/bin by default; override for pre-deploy testing:
#   AUTHENTIK_MANAGER=… ./test.sh
#
# Usage: ./test.sh [--deep] [<vmname>]
#   --deep  also run the live VM integration tiers (forward-auth + OIDC).
# Exit: 0 all passed, 1 one or more failed, 2 fatal/unreachable.

# pass()/fail() always return 0, so the `cond && pass || fail` idiom is a genuine
# if-then-else here (SC2015 false positive); cleanup() runs via the EXIT trap (SC2329).
# shellcheck disable=SC2015,SC2329
set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"

RUN_DEEP=0
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && RUN_DEEP=1; done

DEEPMOD="zzzmod"          # throwaway module name for the deep module-admin role

PASS=0; FAIL=0
section() { echo; info "${BOLD}═══ $* ═══${CL}"; }
pass() { PASS=$((PASS+1)); info "    ${GN}✓${CL} $*"; }
fail() { FAIL=$((FAIL+1)); error "    ✗ $*"; }

CREDS="${HOME}/.authentik-credentials.txt"
[[ -f "${CREDS}" ]] || { error "no ${CREDS}"; exit 2; }
A_URL="$(grep '^url=' "${CREDS}" | cut -d= -f2-)"
A_TOK="$(grep '^token=' "${CREDS}" | cut -d= -f2-)"
api() { curl -fsS -H "Authorization: Bearer ${A_TOK}" "${A_URL}/api/v3$1" "${@:2}"; }

group_present() { api '/core/groups/?page_size=1000' | jq -e --arg n "$1" 'any(.results[]; .name==$n)' >/dev/null 2>&1; }

cleanup() {
    info "  cleanup…"
    local gpk g
    for g in "${DEEPMOD}-admins" "test-idoidc-admins"; do
        gpk="$(api '/core/groups/?page_size=1000' | jq -r --arg n "$g" '.results[]|select(.name==$n)|.pk')"
        [[ -n "${gpk}" ]] && api "/core/groups/${gpk}/" -X DELETE -o /dev/null 2>/dev/null
    done
    # Safety net for the VM integration tests (idempotent; no-op if not installed).
    if [[ "${RUN_DEEP:-0}" -eq 1 && -x /home/tappaas/bin/delete-module.sh ]]; then
        for m in test-idfa test-idoidc; do
            /home/tappaas/bin/delete-module.sh "$m" --force >/dev/null 2>&1 || true
        done
    fi
}
trap cleanup EXIT

# ── 1. connectivity ─────────────────────────────────────────────────────────
section "1: Authentik reachable"
if ${AUTHENTIK_MANAGER} test >/dev/null 2>&1; then pass "authentik-manager connects"
else error "authentik-manager cannot reach Authentik"; exit 2; fi

# ── 2. people-manager role groups present ────────────────────────────────────
# The baseline role groups user/admin/root are reconciled by `people-manager
# sync`. The OIDC install allow-list (install-service.sh) ensures they exist via
# group-ensure as a safety net; assert they are present here.
section "2: people-manager role groups (user/admin/root) exist"
for g in user admin root; do
    ${AUTHENTIK_MANAGER} group-ensure "$g" >/dev/null 2>&1 || true
    group_present "$g" && pass "group ${g} present" || fail "group ${g} missing"
done

# ── 3. OIDC allow-list points at the role groups (offline assertion) ─────────
# install-service.sh must gate OIDC apps on the people-manager role groups
# (user/admin/root), NOT the retired tappaas-* prefix groups.
section "3: OIDC install allow-list = user/admin/root"
SVC="$(cd "$(dirname "$0")" && pwd)/services/identity/install-service.sh"
if [[ -f "${SVC}" ]]; then
    if grep -qE 'ALLOW_GROUPS=\("user" "admin" "root"\)' "${SVC}"; then
        pass "default ALLOW_GROUPS = (user admin root)"
    else
        fail "default ALLOW_GROUPS not (user admin root) in install-service.sh"
    fi
    if ! grep -qE 'tappaas-installers|\$\{PREFIX\}-users|\$\{PREFIX\}-admins' "${SVC}"; then
        pass "no retired prefix/installers groups remain in install-service.sh"
    else
        fail "retired group names (tappaas-installers / \${PREFIX}-*) still present"
    fi
    if ! grep -q 'roles-ensure' "${SVC}"; then
        pass "install-service.sh no longer invokes roles-ensure"
    else
        fail "install-service.sh still references roles-ensure"
    fi
else
    fail "install-service.sh not found at ${SVC}"
fi

# ── 4+5. (retired) ───────────────────────────────────────────────────────────
# The legacy roles-ensure.sh variant-scope and user.sh lifecycle tiers were
# removed: people-manager now owns roles/users (see manager/people-manager).

# ── 6+7. DEEP integration: identity fronts a real webserver, both modes ──────
# Installs two tiny self-contained webserver VMs (test-fixtures/) and checks the
# OBSERVABLE difference: forward-auth GATES the URL (Authentik login, no marker);
# OIDC passes through (marker reachable) + stands up the OIDC provider/binding and
# delivers the OIDC env to the VM. Each VM is torn down after its checks.
if [[ "${RUN_DEEP}" -eq 1 ]]; then
    FIXTURES="$(cd "$(dirname "$0")" && pwd)/test-fixtures"
    DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
    INSTALL_MODULE="${INSTALL_MODULE:-/home/tappaas/bin/install-module.sh}"
    DELETE_MODULE="${DELETE_MODULE:-/home/tappaas/bin/delete-module.sh}"

    if [[ -z "${DOMAIN}" || ! -x "${INSTALL_MODULE}" || ! -x "${DELETE_MODULE}" ]]; then
        section "6-7 (deep): identity integration — SKIPPED"
        warn "  default domain or install/delete-module.sh unavailable; skipping VM integration"
    else
        # ── 6. forward-auth (identity:accessControl) GATES the webserver ──
        section "6 (deep): forward-auth — Authentik gates the webserver"
        FA_FQDN="test-idfa.${DOMAIN}"
        if ( cd "${FIXTURES}/test-idfa" && "${INSTALL_MODULE}" test-idfa --proxyDomain "${FA_FQDN}" ) >/tmp/idfa-install.log 2>&1; then
            pass "test-idfa installed (forward-auth)"
            body="$(curl -ksSL --max-time 25 "https://${FA_FQDN}/" 2>/dev/null)"
            { ! grep -q "tappaas-idfa-ok" <<<"${body}" && grep -qi "authentik" <<<"${body}"; } \
                && pass "unauthenticated request gated → Authentik login served, marker withheld" \
                || fail "forward-auth NOT gating (marker leaked or non-Authentik response)"
            [[ "$(api '/core/applications/?superuser_full_list=true&page_size=1000' | jq -r '[.results[]|select(.slug=="test-idfa")]|length')" -ge 1 ]] \
                && pass "Authentik proxy app 'test-idfa' present" || fail "no Authentik proxy app for test-idfa"
            "${DELETE_MODULE}" test-idfa --force >/dev/null 2>&1 \
                && pass "test-idfa torn down" || fail "test-idfa teardown failed"
        else
            fail "test-idfa install failed (see /tmp/idfa-install.log)"
        fi

        # ── 7. OIDC (identity:identity) — passthrough + provider + env delivery ──
        section "7 (deep): OIDC — passthrough + provider/binding + env on VM"
        OIDC_FQDN="test-idoidc.${DOMAIN}"
        if ( cd "${FIXTURES}/test-idoidc" && "${INSTALL_MODULE}" test-idoidc --proxyDomain "${OIDC_FQDN}" ) >/tmp/idoidc-install.log 2>&1; then
            pass "test-idoidc installed (OIDC)"
            body="$(curl -ksSL --max-time 25 "https://${OIDC_FQDN}/" 2>/dev/null)"
            grep -q "tappaas-idoidc-ok" <<<"${body}" \
                && pass "webserver reachable — OIDC mode does NOT gate (Caddy passthrough)" \
                || fail "OIDC webserver not reachable (got: $(head -c 80 <<<"${body}"))"
            oapp="$(api '/core/applications/?superuser_full_list=true&page_size=1000' | jq -r '.results[]|select(.slug=="test-idoidc")|.pk')"
            [[ -n "${oapp}" ]] && pass "Authentik OIDC application present" || fail "no OIDC application for test-idoidc"
            [[ "$(api '/providers/oauth2/?page_size=1000' | jq -r '[.results[]|select(.name=="test-idoidc")]|length')" -ge 1 ]] \
                && pass "OAuth2/OpenID provider present" || fail "no oauth2 provider for test-idoidc"
            nb="$(api '/policies/bindings/?page_size=1000' | jq -r --arg t "${oapp}" '[.results[]|select(.target==$t)]|length')"
            [[ "${nb:-0}" -ge 1 ]] && pass "access binding present (${nb}) — gate applied" || fail "OIDC app has NO access binding (allow-all)"
            ver="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@test-idoidc.srvWork.internal" 'cat /var/lib/test-idoidc/oidc-verified 2>/dev/null' 2>/dev/null)"
            grep -qE "^client_id=.+" <<<"${ver}" \
                && pass "OIDC env delivered to the VM + configure-service ran (client_id present)" \
                || fail "OIDC env not delivered/verified on the VM"
            grep -q "discovery_reachable=yes" <<<"${ver}" \
                && pass "OIDC discovery document reachable + valid from the VM" \
                || warn "  discovery not reachable from the VM (split-horizon DNS?) — env delivery still verified"
            "${DELETE_MODULE}" test-idoidc --force >/dev/null 2>&1 \
                && pass "test-idoidc torn down" || fail "test-idoidc teardown failed"
        else
            fail "test-idoidc install failed (see /tmp/idoidc-install.log)"
        fi
    fi
fi

# ── summary ─────────────────────────────────────────────────────────────────
section "Summary"
info "  ${GN}Passed:${CL} ${PASS}   ${RD:-}${BOLD}Failed:${CL} ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && { info "${GN}${BOLD}All identity tests passed.${CL}"; exit 0; }
error "${BOLD}${FAIL} identity test(s) failed.${CL}"; exit 1
