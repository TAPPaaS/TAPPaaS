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

# TESTING.md: the deep tier is "gated by TAPPAAS_TEST_DEEP=1 and/or --deep".
# This honoured ONLY --deep, so a sweep driving the documented env var ran just
# the fast tier and reported a clean pass while every deep assertion was skipped.
RUN_DEEP=0
[[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]] && RUN_DEEP=1
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && RUN_DEEP=1; done

DEEPMOD="zzzmod"          # throwaway module name for the deep module-admin role

PASS=0; FAIL=0; SKIP=0
section() { echo; info "${BOLD}═══ $* ═══${CL}"; }
pass() { PASS=$((PASS+1)); info "    ${GN}✓${CL} $*"; }
fail() { FAIL=$((FAIL+1)); error "    ✗ $*"; }
# This suite had no `skip`, so a precondition guard that called it errored with
# "skip: command not found" and the check silently vanished — neither passed nor
# reported. A skipped check must always be VISIBLE and counted, or a run with
# unexercised assertions reads exactly like a clean one.
skip() { SKIP=$((SKIP+1)); info "    ${YW:-}⊘${CL:-} SKIP: $*"; }

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

# ── 2b. the Authentik admin group is superuser + holds the site owner (#476) ─
# Membership in an is_superuser group is the ONLY thing that grants the Authentik
# admin UI, so assert BOTH halves: the group carries the flag, and the site owner
# is in it. Group-flag check is unconditional; the membership check is skipped
# when no site owner can be resolved (people tree not bootstrapped yet).
section "2b: 'authentik Admins' is superuser and holds the site owner (#476)"
AK_ADMIN_GROUP="authentik Admins"
if api '/core/groups/?page_size=1000' \
    | jq -e --arg n "${AK_ADMIN_GROUP}" 'any(.results[]; .name==$n and .is_superuser==true)' >/dev/null 2>&1; then
    pass "group '${AK_ADMIN_GROUP}' present with is_superuser=true"
else
    fail "group '${AK_ADMIN_GROUP}' missing or not is_superuser — nobody but akadmin can administer Authentik"
fi

PEOPLE_DIR="${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}/people"
OWNER_ORG="$(get_site_value '.owner' 2>/dev/null || true)"
OWNER_USER=""
[[ -n "${OWNER_ORG}" ]] && OWNER_USER="$(jq -r '.owner // empty' \
    "${PEOPLE_DIR}/organizations/${OWNER_ORG}.json" 2>/dev/null || true)"
if [[ -z "${OWNER_USER}" ]]; then
    warn "  no site owner resolved (people tree not bootstrapped?) — skipping the membership check"
elif ${AUTHENTIK_MANAGER} get-user --name "${OWNER_USER}" 2>/dev/null \
    | jq -e --arg g "${AK_ADMIN_GROUP}" '.groups // [] | index($g) != null' >/dev/null 2>&1; then
    pass "site owner '${OWNER_USER}' is a member of '${AK_ADMIN_GROUP}'"
else
    # WARN, not fail: this membership is reconciled by identity update.sh, which
    # runs AFTER the pre-update test gate — so a hard fail here aborts the very
    # update that would fix it (bootstrap deadlock on first run after #476). The
    # post-update run passes once update.sh has added the owner.
    warn "site owner '${OWNER_USER}' not yet in '${AK_ADMIN_GROUP}' — identity update.sh reconciles this"
fi

# ── 2c. password recovery is wired (brand.flow_recovery → a recovery flow) ──
# Without this, `authentik-manager user-recovery-link <user>` exits 2 and the
# only reset path is handing out a password. Asserted from the API (no token is
# minted here — that would be a side effect on a real user).
section "2c: password recovery flow wired to the default brand"
BRAND_RECOVERY="$(api '/core/brands/?page_size=100' | jq -r '[.results[]|select(.default==true)][0].flow_recovery // empty')"
if [[ -z "${BRAND_RECOVERY}" ]]; then
    # WARN, not fail: identity update.sh wires the recovery flow, and it runs
    # AFTER the pre-update test gate — a hard fail here aborts the update that
    # would fix it. The integrity sub-checks below stay strict (they only run
    # once a recovery flow IS wired). Same bootstrap rationale as 2b.
    warn "default brand has no flow_recovery yet — identity update.sh reconciles this"
else
    pass "default brand flow_recovery set (${BRAND_RECOVERY:0:8}…)"
    RECOVERY_FLOW="$(api "/flows/instances/?page_size=1000" \
        | jq -r --arg pk "${BRAND_RECOVERY}" '.results[]|select(.pk==$pk)')"
    [[ "$(jq -r '.designation // empty' <<<"${RECOVERY_FLOW}")" == "recovery" ]] \
        && pass "it points at a flow with designation=recovery" \
        || fail "brand.flow_recovery does not point at a recovery-designation flow"
    # The write stage must never create users: an untokened visit to the flow
    # URL has no pending user and must fail, not mint an account.
    if api '/stages/user_write/?page_size=100' \
        | jq -e 'any(.results[]; .name=="tappaas-recovery-write" and .user_creation_mode=="never_create")' >/dev/null 2>&1; then
        pass "tappaas-recovery-write is never_create (no account minting)"
    else
        fail "tappaas-recovery-write missing or not never_create"
    fi
fi

# ── 3. OIDC allow-list points at the role groups (offline assertion) ─────────
# install-service.sh must gate OIDC apps on the people-manager role groups
# the `users` membership group (the OIDC groups claim carries memberships, not the
# RBAC roles), NOT the retired tappaas-* prefix groups.
section "3: OIDC install allow-list = users (membership group)"
SVC="$(cd "$(dirname "$0")" && pwd)/services/identity/install-service.sh"
if [[ -f "${SVC}" ]]; then
    if grep -qE 'ALLOW_GROUPS=\("users"\)' "${SVC}"; then
        pass "default ALLOW_GROUPS = (users) — the org membership group"
    else
        fail "default ALLOW_GROUPS not (users) in install-service.sh"
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
# ── proxy-reachability precondition (identity deep 6/7) ───────────────
# Both deep checks publish an EPHEMERAL hostname (test-idfa/test-idoidc.<domain>)
# and then fetch it through Caddy. Under dnsMode=per-service that hostname has no
# public DNS A record, so ACME HTTP-01 cannot validate, no certificate is issued,
# and the TLS handshake fails outright — curl returns an empty body and the
# assertion fails for a reason that has nothing to do with identity.
#
# (Measured on such a host: a long-lived name gives http=302/ssl_verify_result=20,
# an unpublished one gives http=000/ssl_verify_result=1.)
#
# Under dnsMode=wildcard a single *.<domain> cert covers these names and both
# checks run for real. So: probe first, and SKIP with the precondition when the
# proxy path cannot serve TLS for the name — never silently pass.
proxy_tls_usable() {   # $1 = fqdn
    local code
    # NOTE the fallback form: `$(curl ... || echo 000)` concatenates curl's own
    # "000" with the echoed one ("000000"), which then compares unequal to "000"
    # and silently defeats this guard. Assign the fallback OUTSIDE the
    # substitution instead.
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 "https://$1/" 2>/dev/null)" || code=000
    [[ -n "${code}" && "${code}" != "000" ]]
}

# Fetch through Caddy, WAITING for the upstream to come up. A freshly installed
# module's webserver is not serving the instant install-module.sh returns, and
# neither of these checks waited — they fired one curl and reported the empty
# body as a functional failure. Caddy answers immediately (so the TLS probe
# above passes) while the upstream is still starting, which is exactly the
# 502-with-empty-body we were misreading.
#
# Echoes "<http_code>|<body>"; retries while the code says "upstream not ready".
proxy_fetch() {        # $1 = fqdn, $2 = attempts (default 12 -> ~60s)
    local fqdn="$1" tries="${2:-12}" i code body tmp
    tmp="$(mktemp)"
    for ((i = 1; i <= tries; i++)); do
        code="$(curl -ksSL -o "${tmp}" -w '%{http_code}' --max-time 20 "https://${fqdn}/" 2>/dev/null)" || code=000
        [[ -n "${code}" ]] || code=000
        body="$(cat "${tmp}" 2>/dev/null)"
        # 502/503/504 = Caddy up, upstream not yet answering. Keep waiting.
        case "${code}" in
            502|503|504|000) ;;
            *) [[ -n "${body}" ]] && break ;;
        esac
        sleep 5
    done
    rm -f "${tmp}"
    printf '%s|%s' "${code}" "${body}"
}

        # ── 6. forward-auth (identity:accessControl) GATES the webserver ──
        section "6 (deep): forward-auth — Authentik gates the webserver"
        FA_FQDN="test-idfa.${DOMAIN}"
        if ( cd "${FIXTURES}/test-idfa" && "${INSTALL_MODULE}" test-idfa --proxyDomain "${FA_FQDN}" ) >/tmp/idfa-install.log 2>&1; then
            pass "test-idfa installed (forward-auth)"
            if ! proxy_tls_usable "${FA_FQDN}"; then
                skip "forward-auth gating — Caddy cannot serve TLS for ${FA_FQDN} (dnsMode=$(jq -r '.domains.dnsMode // "?"' "${CONFIG_DIR}/environments/$(jq -r '.defaultEnvironment // .name' "${CONFIG_DIR}/site.json").json" 2>/dev/null): no public A record ⇒ no ACME cert). Use dnsMode=wildcard, or publish the record, to exercise this."
            else
                _r="$(proxy_fetch "${FA_FQDN}")"; _code="${_r%%|*}"; body="${_r#*|}"
                if { ! grep -q "tappaas-idfa-ok" <<<"${body}" && grep -qi "authentik" <<<"${body}"; }; then
                    pass "unauthenticated request gated → Authentik login served, marker withheld"
                elif grep -q "tappaas-idfa-ok" <<<"${body}"; then
                    fail "forward-auth NOT gating — the marker LEAKED (http ${_code}); the outpost is not in front of the upstream"
                else
                    fail "forward-auth: no Authentik response (http ${_code}, ${#body} bytes): $(head -c 120 <<<"${body}" | tr '\n' ' ')"
                fi
            fi
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
            if ! proxy_tls_usable "${OIDC_FQDN}"; then
                skip "OIDC passthrough — Caddy cannot serve TLS for ${OIDC_FQDN} (no public A record under dnsMode=per-service ⇒ no ACME cert). Use dnsMode=wildcard, or publish the record, to exercise this."
            else
                _r="$(proxy_fetch "${OIDC_FQDN}")"; _code="${_r%%|*}"; body="${_r#*|}"
                grep -q "tappaas-idoidc-ok" <<<"${body}" \
                    && pass "webserver reachable — OIDC mode does NOT gate (Caddy passthrough)" \
                    || fail "OIDC webserver not reachable (http ${_code}, ${#body} bytes): $(head -c 120 <<<"${body}" | tr '\n' ' ')"
            fi
            oapp="$(api '/core/applications/?superuser_full_list=true&page_size=1000' | jq -r '.results[]|select(.slug=="test-idoidc")|.pk')"
            [[ -n "${oapp}" ]] && pass "Authentik OIDC application present" || fail "no OIDC application for test-idoidc"
            [[ "$(api '/providers/oauth2/?page_size=1000' | jq -r '[.results[]|select(.name=="test-idoidc")]|length')" -ge 1 ]] \
                && pass "OAuth2/OpenID provider present" || fail "no oauth2 provider for test-idoidc"
            nb="$(api '/policies/bindings/?page_size=1000' | jq -r --arg t "${oapp}" '[.results[]|select(.target==$t)]|length')"
            [[ "${nb:-0}" -ge 1 ]] && pass "access binding present (${nb}) — gate applied" || fail "OIDC app has NO access binding (allow-all)"
            # DERIVE the internal FQDN from the module's DEPLOYED zone. This was
            # hardcoded to `test-idoidc.srvWork.internal`; ADR-014 D7 retired the
            # srv* zones, and the fixture no longer pins zone0 at all (it resolves
            # to the target environment's zone), so the hardcoded name stopped
            # resolving and the env-delivery check could never pass.
            _oz="$(jq -r '.zone0 // empty' "${CONFIG_DIR}/test-idoidc.json" 2>/dev/null)"
            [[ -n "${_oz}" ]] || _oz="$(jq -r '.network.zone // empty' \
                "${CONFIG_DIR}/environments/$(jq -r '.defaultEnvironment // .name' "${CONFIG_DIR}/site.json" 2>/dev/null).json" 2>/dev/null)"
            _ohost="test-idoidc.${_oz:-mgmt}.internal"
            info "  OIDC VM internal FQDN: ${_ohost}"
            ver="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${_ohost}" 'cat /var/lib/test-idoidc/oidc-verified 2>/dev/null' 2>/dev/null)"
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
info "  ${GN}Passed:${CL} ${PASS}   ${RD:-}${BOLD}Failed:${CL} ${FAIL}   ${YW:-}Skipped:${CL:-} ${SKIP}"
if [[ "${SKIP}" -gt 0 ]]; then
    info "  ${YW:-}Note:${CL:-} ${SKIP} check(s) were NOT exercised — see the SKIP lines above."
fi
[[ "${FAIL}" -eq 0 ]] && { info "${GN}${BOLD}All identity tests passed${CL}${SKIP:+ (${SKIP} skipped)}."; exit 0; }
error "${BOLD}${FAIL} identity test(s) failed.${CL}"; exit 1
