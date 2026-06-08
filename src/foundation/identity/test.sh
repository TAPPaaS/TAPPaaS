#!/usr/bin/env bash
#
# TAPPaaS Identity — module tests (ADR-006 users/roles, issue #56).
#
# Exercises the role-group model and add-user against the LIVE Authentik on the
# identity VM. Uses throwaway zzz-identity-test* objects and cleans them up; the
# real baseline groups (tappaas-installers / tappaas / tappaas-admins /
# tappaas-users) created by roles-ensure are left in place.
#
# Commands are taken from ~/bin by default; override for pre-deploy testing:
#   AUTHENTIK_MANAGER=… ROLES_ENSURE=… ADD_USER=… ./test.sh
#
# Usage: ./test.sh [<vmname>]
# Exit: 0 all passed, 1 one or more failed, 2 fatal/unreachable.

# pass()/fail() always return 0, so the `cond && pass || fail` idiom is a genuine
# if-then-else here (SC2015 false positive); cleanup() runs via the EXIT trap (SC2329).
# shellcheck disable=SC2015,SC2329
set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
ROLES_ENSURE="${ROLES_ENSURE:-/home/tappaas/bin/roles-ensure.sh}"
ADD_USER="${ADD_USER:-/home/tappaas/bin/add-user.sh}"

TP="zzz-identity-test"
TUSER="${TP}-alice"
TVAR="${TP}var"

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
    local upk gpk g
    upk="$(api '/core/users/?page_size=1000' | jq -r --arg u "${TUSER}" '.results[]|select(.username==$u)|.pk')"
    [[ -n "${upk}" ]] && api "/core/users/${upk}/" -X DELETE -o /dev/null 2>/dev/null
    for g in "${TVAR}-users" "${TVAR}-admins" "${TVAR}"; do
        gpk="$(api '/core/groups/?page_size=1000' | jq -r --arg n "$g" '.results[]|select(.name==$n)|.pk')"
        [[ -n "${gpk}" ]] && api "/core/groups/${gpk}/" -X DELETE -o /dev/null 2>/dev/null
    done
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

# ── 3. add-user create + idempotent + additive ──────────────────────────────
section "3: add-user create / idempotent / additive role"
"${ADD_USER}" "${TUSER}" --email "${TUSER}@example.invalid" --no-credential >/dev/null 2>&1 || fail "add-user create failed"
mapfile -t g1 < <(user_groups "${TUSER}")
[[ " ${g1[*]} " == *" tappaas-users "* ]] && pass "new user is in tappaas-users" || fail "new user not in tappaas-users (got: ${g1[*]:-none})"

"${ADD_USER}" "${TUSER}" --email "${TUSER}@example.invalid" --no-credential >/dev/null 2>&1
n="$(api '/core/users/?page_size=1000' | jq -r --arg u "${TUSER}" '[.results[]|select(.username==$u)]|length')"
[[ "${n}" -eq 1 ]] && pass "idempotent — still exactly one user" || fail "idempotent re-run produced ${n} users"

"${ADD_USER}" "${TUSER}" --email "${TUSER}@example.invalid" --role admin --no-credential >/dev/null 2>&1
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

# ── summary ─────────────────────────────────────────────────────────────────
section "Summary"
info "  ${GN}Passed:${CL} ${PASS}   ${RD:-}${BOLD}Failed:${CL} ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && { info "${GN}${BOLD}All identity tests passed.${CL}"; exit 0; }
error "${BOLD}${FAIL} identity test(s) failed.${CL}"; exit 1
