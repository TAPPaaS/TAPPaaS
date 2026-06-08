#!/usr/bin/env bash
#
# TAPPaaS Identity — module tests (ADR-006 users/roles, issue #56).
#
# Exercises the role-group model and user.sh against the LIVE Authentik on the
# identity VM. Uses throwaway zzz-identity-test* objects and cleans them up; the
# real baseline groups (tappaas-installers / tappaas / tappaas-admins /
# tappaas-users) created by roles-ensure are left in place.
#
# Commands are taken from ~/bin by default; override for pre-deploy testing:
#   AUTHENTIK_MANAGER=… ROLES_ENSURE=… USER_SH=… ./test.sh
#
# Usage: ./test.sh [--deep] [<vmname>]
#   --deep  also run the full user.sh lifecycle (add → modify membership → delete).
# Exit: 0 all passed, 1 one or more failed, 2 fatal/unreachable.

# pass()/fail() always return 0, so the `cond && pass || fail` idiom is a genuine
# if-then-else here (SC2015 false positive); cleanup() runs via the EXIT trap (SC2329).
# shellcheck disable=SC2015,SC2329
set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
ROLES_ENSURE="${ROLES_ENSURE:-/home/tappaas/bin/roles-ensure.sh}"
USER_SH="${USER_SH:-/home/tappaas/bin/user.sh}"

RUN_DEEP=0
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && RUN_DEEP=1; done

TP="zzz-identity-test"
TUSER="${TP}-alice"
TVAR="${TP}var"
DEEPUSER="${TP}-deep"
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

group_attr() { api '/core/groups/?page_size=1000' | jq -r --arg n "$1" '.results[]|select(.name==$n)|.attributes|tostring'; }
group_super() { api '/core/groups/?page_size=1000' | jq -r --arg n "$1" '.results[]|select(.name==$n)|.is_superuser'; }
user_groups() { api '/core/users/?page_size=1000' | jq -r --arg u "$1" '.results[]|select(.username==$u)|.groups_obj[].name'; }

cleanup() {
    info "  cleanup…"
    local upk gpk g u
    for u in "${TUSER}" "${DEEPUSER}"; do
        upk="$(api '/core/users/?page_size=1000' | jq -r --arg u "$u" '.results[]|select(.username==$u)|.pk')"
        [[ -n "${upk}" ]] && api "/core/users/${upk}/" -X DELETE -o /dev/null 2>/dev/null
    done
    for g in "${TVAR}-users" "${TVAR}-admins" "${TVAR}" "tappaas-${DEEPMOD}-admins" \
             "tappaas-test-idoidc-admins"; do
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

# ── 2. roles-ensure baseline groups ─────────────────────────────────────────
section "2: roles-ensure creates the baseline role groups"
"${ROLES_ENSURE}" >/dev/null 2>&1 || fail "roles-ensure exited non-zero"
[[ "$(group_super tappaas-installers)" == "true" ]] && pass "tappaas-installers is superuser" || fail "tappaas-installers missing/not superuser"
for g in tappaas tappaas-admins tappaas-users; do
    [[ -n "$(group_attr "$g")" && "$(group_attr "$g")" != "null" ]] && pass "group ${g} present" || fail "group ${g} missing"
done
[[ "$(group_attr tappaas-users | jq -r '.tappaas.role')" == "user" ]] && pass "tappaas-users has role=user attr" || fail "tappaas-users attr wrong"

# ── 3. user.sh add: create + idempotent + additive ──────────────────────────────
section "3: user.sh add — create / idempotent / additive role"
"${USER_SH}" add "${TUSER}" --email "${TUSER}@example.invalid" --no-credential >/dev/null 2>&1 || fail "user.sh add failed"
mapfile -t g1 < <(user_groups "${TUSER}")
[[ " ${g1[*]} " == *" tappaas-users "* ]] && pass "new user is in tappaas-users" || fail "new user not in tappaas-users (got: ${g1[*]:-none})"

"${USER_SH}" add "${TUSER}" --email "${TUSER}@example.invalid" --no-credential >/dev/null 2>&1
n="$(api '/core/users/?page_size=1000' | jq -r --arg u "${TUSER}" '[.results[]|select(.username==$u)]|length')"
[[ "${n}" -eq 1 ]] && pass "idempotent — still exactly one user" || fail "idempotent re-run produced ${n} users"

"${USER_SH}" add "${TUSER}" --email "${TUSER}@example.invalid" --role admin --no-credential >/dev/null 2>&1
mapfile -t g2 < <(user_groups "${TUSER}")
{ [[ " ${g2[*]} " == *" tappaas-users "* ]] && [[ " ${g2[*]} " == *" tappaas-admins "* ]]; } \
    && pass "additive — user now in BOTH tappaas-users and tappaas-admins" \
    || fail "additive role failed (got: ${g2[*]:-none})"

# ── 4. variant scope isolation (group model) ────────────────────────────────
section "4: a variant user is NOT in the default scope's groups"
"${ROLES_ENSURE}" --variant "${TVAR}" >/dev/null 2>&1 || fail "roles-ensure --variant failed"
# Put a fresh membership on the SAME test user for the variant scope.
${AUTHENTIK_MANAGER} user-add-to-groups "${TUSER}" --group "${TVAR}-users" >/dev/null 2>&1 || fail "could not add to ${TVAR}-users"
mapfile -t g3 < <(user_groups "${TUSER}")
[[ " ${g3[*]} " == *" ${TVAR}-users "* ]] && pass "user added to ${TVAR}-users" || fail "user not in ${TVAR}-users"
# The variant's child group must be a DISTINCT group from the default's (parent differs).
vp="$(api '/core/groups/?page_size=1000' | jq -r --arg n "${TVAR}-users" '.results[]|select(.name==$n)|.parent')"
tp="$(api '/core/groups/?page_size=1000' | jq -r --arg n "tappaas-users" '.results[]|select(.name==$n)|.parent')"
[[ -n "${vp}" && "${vp}" != "${tp}" && "${vp}" != "null" ]] \
    && pass "${TVAR}-users has its own parent scope (≠ default) → isolation by group" \
    || fail "variant scope parent not distinct (vp=${vp} tp=${tp})"

# ── 5. DEEP: full user.sh lifecycle (add → modify → delete) ──────────────────
if [[ "${RUN_DEEP}" -eq 1 ]]; then
    section "5 (deep): user.sh lifecycle — add / modify membership / delete"
    DG="tappaas-${DEEPMOD}-admins"

    # create
    "${USER_SH}" add "${DEEPUSER}" --email "${DEEPUSER}@example.invalid" --name "Deep User" \
        --role user --no-credential >/dev/null 2>&1 || fail "deep: user.sh add failed"
    mapfile -t d1 < <(user_groups "${DEEPUSER}")
    [[ " ${d1[*]} " == *" tappaas-users "* ]] \
        && pass "created — in tappaas-users" || fail "not in tappaas-users (got: ${d1[*]:-none})"

    # modify membership: +admin +module-admin:zzzmod, -user
    "${USER_SH}" modify "${DEEPUSER}" --add-role admin --add-role "module-admin:${DEEPMOD}" \
        --remove-role user >/dev/null 2>&1 || fail "deep: user.sh modify (roles) failed"
    mapfile -t d2 < <(user_groups "${DEEPUSER}")
    { [[ " ${d2[*]} " == *" tappaas-admins "* ]] && [[ " ${d2[*]} " == *" ${DG} "* ]] \
        && [[ " ${d2[*]} " != *" tappaas-users "* ]]; } \
        && pass "modify — added admin + ${DG}, removed user" \
        || fail "modify membership wrong (got: ${d2[*]:-none})"

    # modify profile: email + name
    "${USER_SH}" modify "${DEEPUSER}" --email "${DEEPUSER}-new@example.invalid" \
        --name "Deep User 2" >/dev/null 2>&1 || fail "deep: user.sh modify (profile) failed"
    em="$(api '/core/users/?page_size=1000' | jq -r --arg u "${DEEPUSER}" '.results[]|select(.username==$u)|.email')"
    [[ "${em}" == "${DEEPUSER}-new@example.invalid" ]] \
        && pass "modify — email updated" || fail "email not updated (got: ${em})"

    # delete
    "${USER_SH}" delete "${DEEPUSER}" --yes >/dev/null 2>&1 || fail "deep: user.sh delete failed"
    gone="$(api '/core/users/?page_size=1000' | jq -r --arg u "${DEEPUSER}" '[.results[]|select(.username==$u)]|length')"
    [[ "${gone}" -eq 0 ]] && pass "deleted — user gone" || fail "user still present after delete"

    # delete idempotent
    "${USER_SH}" delete "${DEEPUSER}" --yes >/dev/null 2>&1 \
        && pass "delete idempotent (no error when absent)" || fail "delete errored on absent user"
fi

# ── 6+7. DEEP integration: identity fronts a real webserver, both modes ──────
# Installs two tiny self-contained webserver VMs (test-fixtures/) and checks the
# OBSERVABLE difference: forward-auth GATES the URL (Authentik login, no marker);
# OIDC passes through (marker reachable) + stands up the OIDC provider/binding and
# delivers the OIDC env to the VM. Each VM is torn down after its checks.
if [[ "${RUN_DEEP}" -eq 1 ]]; then
    FIXTURES="$(cd "$(dirname "$0")" && pwd)/test-fixtures"
    DOMAIN="$(jq -r '(.tappaas.variants[""].domain // .tappaas.domain // "")' "${CONFIG_DIR}/configuration.json")"
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
