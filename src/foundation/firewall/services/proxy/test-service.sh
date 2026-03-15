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
VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null)

PROXY_DOMAIN=$(jq -r '.proxyDomain // empty' "${MODULE_JSON}")
if [[ -z "${PROXY_DOMAIN}" && -n "${TAPPAAS_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

PROXY_PORT=$(jq -r '.proxyPort // 80' "${MODULE_JSON}")
UPSTREAM="${VMNAME}.${ZONE}.internal"

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
if [[ -n "${PROXY_DOMAIN}" ]]; then
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --max-time 10 --resolve "${PROXY_DOMAIN}:443:$(dig +short A "${PROXY_DOMAIN}" 2>/dev/null | head -1)" \
        "https://${PROXY_DOMAIN}/" 2>/dev/null) || true
    if [[ "${http_code}" =~ ^(200|301|302|303|307|308)$ ]]; then
        pass "HTTPS responding (status ${http_code})"
    elif [[ -n "${http_code}" && "${http_code}" != "000" ]]; then
        # Got a response but not a redirect/success — warn but pass
        pass "HTTPS responding (status ${http_code} — may require auth)"
    else
        fail "HTTPS not responding (status: ${http_code:-timeout})"
    fi
else
    fail "Cannot determine proxy domain"
fi

# ── Deep mode tests ─────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 4: TLS certificate validity
    info "  Check 4: TLS certificate"
    if [[ -n "${PROXY_DOMAIN}" ]]; then
        cert_expiry=$(echo | openssl s_client -servername "${PROXY_DOMAIN}" \
            -connect "${PROXY_DOMAIN}:443" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null \
            | sed 's/notAfter=//') || true

        if [[ -n "${cert_expiry}" ]]; then
            expiry_epoch=$(date -d "${cert_expiry}" +%s 2>/dev/null) || true
            now_epoch=$(date +%s)
            if [[ -n "${expiry_epoch}" && "${expiry_epoch}" -gt "${now_epoch}" ]]; then
                days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                pass "TLS certificate valid (expires in ${days_left} days)"
            else
                fail "TLS certificate expired or expiry unparseable"
            fi
        else
            fail "Could not retrieve TLS certificate"
        fi
    else
        fail "Cannot check TLS — no proxy domain"
    fi

    # Test 5: Upstream reachable from firewall
    info "  Check 5: Upstream reachability"
    FIREWALL_FQDN="firewall.mgmt.internal"
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
