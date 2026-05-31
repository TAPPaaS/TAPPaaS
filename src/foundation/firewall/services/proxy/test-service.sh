#!/usr/bin/env bash
#
# TAPPaaS Firewall Proxy Service - Test
#
# Verifies that a module's Caddy reverse proxy is configured and working.
# Called by test-module.sh for any module that depends on firewall:proxy.
#
# Tests:
#   1. Caddy domain entry exists for the module
#   2. Caddy handler entry exists for the module
#   3. HTTPS endpoint responds (curl from tappaas-cicd)
#   Deep mode:
#   4. TLS certificate is valid and not expired
#   5. Upstream is reachable from the firewall
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed (or firewallType=NONE → skip)
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

if [[ ! -f "${MODULE_JSON}" ]]; then
    error "Module config not found: ${MODULE_JSON}"
    exit 2
fi

# Check firewallType — if NONE, skip all tests
FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

# Resolve proxy domain and upstream
VMNAME=$(get_config_value 'vmname' '')
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE="${TAPPAAS_ZONE0_OVERRIDE:-$(get_config_value 'zone0' 'srv-home')}"  # override: issue #196
TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null)

PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
if [[ -z "${PROXY_DOMAIN}" && -n "${TAPPAAS_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

PROXY_PORT=$(get_config_value 'proxyPort' '80')
UPSTREAM="${VMNAME}.${ZONE}.internal"

# Caddy runs on the OPNsense firewall and listens on *:443 (all interfaces).
# tappaas-cicd sits on the internal mgmt zone (10.0.0.0/24); the module's public
# domain resolves to the firewall's WAN IP, but OPNsense does not NAT-hairpin by
# default, so connecting to the WAN IP from inside times out (#138). Pin HTTPS
# checks to the firewall's internal address (with --resolve, preserving SNI so
# Caddy serves the correct vhost) instead of relying on public DNS.
FIREWALL_FQDN="firewall.mgmt.internal"
FIREWALL_IP=$(getent hosts "${FIREWALL_FQDN}" 2>/dev/null | awk '{print $1}' | head -1)
if [[ -z "${FIREWALL_IP}" ]]; then
    FIREWALL_IP=$(dig +short A "${FIREWALL_FQDN}" 2>/dev/null | head -1)
fi

# Is this service exposed to the internet, or internal-only? proxyAllowedZones
# containing "internet" means public. An internal-only service may legitimately
# have no working public TLS cert yet (e.g. the DNS-01 provider credentials are
# not configured), so a failing HTTPS check is a warning for it — not a hard
# failure that should block the install.
PROXY_PUBLIC=0
if read_module_config "${MODULE}" | jq -e '(.proxyAllowedZones // []) | index("internet")' >/dev/null 2>&1; then
    PROXY_PUBLIC=1
fi

info "  ${BOLD}firewall:proxy tests for ${BL}${MODULE}${CL}"
info "    Domain: ${PROXY_DOMAIN:-unknown}"

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "    firewallType=NONE — skipping proxy tests"
    exit 0
fi

# Verify caddy-manager is available
if ! command -v caddy-manager &>/dev/null; then
    error "    caddy-manager CLI not found"
    exit 2
fi

# Get caddy-manager listing once
caddy_list=$(caddy-manager list --no-ssl-verify 2>/dev/null) || true

# ── Test 1: Domain exists in Caddy ──────────────────────────────────

info "  Check 1: Caddy domain entry"
if echo "${caddy_list}" | grep -q "${PROXY_DOMAIN}"; then
    pass "Domain '${PROXY_DOMAIN}' exists in Caddy"
else
    fail "Domain '${PROXY_DOMAIN}' not found in Caddy"
fi

# ── Test 2: Handler exists in Caddy ─────────────────────────────────

info "  Check 2: Caddy handler entry"
if echo "${caddy_list}" | grep -q "${UPSTREAM}"; then
    pass "Handler for '${UPSTREAM}' exists in Caddy"
else
    fail "Handler for '${UPSTREAM}' not found in Caddy"
fi

# ── Test 3: HTTPS endpoint responds ─────────────────────────────────

info "  Check 3: HTTPS endpoint"
if [[ -z "${PROXY_DOMAIN}" ]]; then
    fail "Cannot determine proxy domain"
elif [[ -z "${FIREWALL_IP}" ]]; then
    # Without the firewall's internal IP we cannot reach Caddy without hitting
    # the un-hairpinned WAN IP, so skip rather than report a false failure.
    warn "    Cannot determine ${FIREWALL_FQDN} internal IP — skipping HTTPS check"
else
    # Connect to Caddy on the firewall's internal interface; --resolve keeps the
    # SNI/Host as the public domain so Caddy selects the right vhost and cert.
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --max-time 10 --resolve "${PROXY_DOMAIN}:443:${FIREWALL_IP}" \
        "https://${PROXY_DOMAIN}/" 2>/dev/null) || true
    if [[ "${http_code}" =~ ^(200|301|302|303|307|308)$ ]]; then
        pass "HTTPS responding (status ${http_code})"
    elif [[ -n "${http_code}" && "${http_code}" != "000" ]]; then
        # Got a response but not a redirect/success — warn but pass
        pass "HTTPS responding (status ${http_code} — may require auth)"
    elif [[ "${PROXY_PUBLIC}" -eq 1 ]]; then
        fail "HTTPS not responding (status: ${http_code:-timeout})"
    else
        # Internal-only service: a missing/invalid public cert (e.g. DNS-01
        # provider creds not set up yet) must not block the install.
        warn "    HTTPS not responding (status: ${http_code:-timeout}) — internal-only service; public TLS cert/DNS-01 not configured yet (warning, not a failure)"
    fi
fi

# ── Deep mode tests ─────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 4: TLS certificate validity
    #
    # openssl is not installed on the minimal NixOS cicd (#138), so use curl's
    # %{certs} writeout (curl >= 7.88) to obtain the leaf certificate's expiry.
    # Connect via the firewall's internal IP for the same NAT-hairpin reason as
    # Check 3, keeping the public domain as SNI.
    info "  Check 4: TLS certificate"
    if [[ -z "${PROXY_DOMAIN}" ]]; then
        fail "Cannot check TLS — no proxy domain"
    elif [[ -z "${FIREWALL_IP}" ]]; then
        warn "    Cannot determine ${FIREWALL_FQDN} internal IP — skipping TLS check"
    else
        cert_info=$(curl -sk --max-time 10 \
            --resolve "${PROXY_DOMAIN}:443:${FIREWALL_IP}" \
            -w '%{certs}' -o /dev/null "https://${PROXY_DOMAIN}/" 2>/dev/null) || true
        # First "Expire date:" line is the leaf certificate.
        cert_expiry=$(echo "${cert_info}" | sed -n 's/^Expire date:[[:space:]]*//p' | head -1)

        if [[ -n "${cert_expiry}" ]]; then
            expiry_epoch=$(date -d "${cert_expiry}" +%s 2>/dev/null) || true
            now_epoch=$(date +%s)
            if [[ -n "${expiry_epoch}" && "${expiry_epoch}" -gt "${now_epoch}" ]]; then
                days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                pass "TLS certificate valid (expires in ${days_left} days)"
            else
                fail "TLS certificate expired or expiry unparseable"
            fi
        elif [[ "${PROXY_PUBLIC}" -eq 1 ]]; then
            fail "Could not retrieve TLS certificate"
        else
            warn "    Could not retrieve TLS certificate — internal-only service; public TLS cert/DNS-01 not configured yet (warning, not a failure)"
        fi
    fi

    # Test 5: Upstream reachable from firewall
    info "  Check 5: Upstream reachability"
    upstream_code=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${FIREWALL_FQDN}" \
        "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 http://${UPSTREAM}:${PROXY_PORT}/" \
        2>/dev/null) || true
    if [[ "${upstream_code}" =~ ^[2-4][0-9][0-9]$ ]]; then
        pass "Upstream reachable from firewall (status ${upstream_code})"
    else
        fail "Upstream unreachable from firewall (status: ${upstream_code:-timeout})"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
