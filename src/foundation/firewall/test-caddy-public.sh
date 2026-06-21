#!/usr/bin/env bash
#
# test-caddy-public.sh — standalone end-to-end Caddy test (ADR-005 #316, Option B).
#
# Proves a service published to the internet via firewall:proxy is reachable
# both from outside (public IP, TLS-terminated + proxied by Caddy) and from
# inside via split-horizon DNS. Deliberately SAFE: it deploys a small NixOS
# webserver in an ALREADY-ACTIVE zone (srvWork) — it does NOT activate zones or
# touch the firewall VM's trunk config (unlike firewall/test.sh --deep, see
# ISSUES/deep-test-trunk-and-nixbuild.md). It creates and destroys one real VM.
#
# Gate (skips unless both hold): the default variant "" has a real domain AND
# public DNS for the service FQDN resolves to a public IP.
#
# Usage: ./test-caddy-public.sh [--no-cleanup]
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIX="${SCRIPT_DIR}/test-fixtures"

# shellcheck source=../tappaas-cicd/lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

readonly MODULE="test-caddy-web"
readonly MARKER="tappaas-caddy-public-ok"
NO_CLEANUP=0
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=1

PASS=0
FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

is_public_ip() {
    local ip="$1"
    [[ -n "${ip}" ]] || return 1
    case "${ip}" in
        10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    esac
    return 0
}

cleanup() {
    local rc=$?
    if [[ "${NO_CLEANUP}" -eq 1 ]]; then
        warn "Skipping cleanup (--no-cleanup): ${MODULE} left deployed."
        return "${rc}"
    fi
    if [[ -f "${CONFIG_DIR}/${MODULE}.json" ]]; then
        info "Cleanup: deleting ${MODULE}..."
        /home/tappaas/bin/delete-module.sh "${MODULE}" --force >/dev/null 2>&1 \
            || warn "delete-module ${MODULE} returned non-zero (manual check advised)"
    fi
    return "${rc}"
}
trap cleanup EXIT

# curl through Caddy at a specific IP, retrying while the VM/Caddy settle.
# Args: <fqdn> <ip> <label>; greps the response for MARKER.
curl_marker() {
    local fqdn="$1" ip="$2" label="$3" body
    for _ in 1 2 3 4 5 6; do
        body="$(curl -fsS --max-time 12 --resolve "${fqdn}:443:${ip}" "https://${fqdn}/" 2>/dev/null || true)"
        if grep -q "${MARKER}" <<<"${body}"; then
            pass "${label}: https://${fqdn} via ${ip} returned the marker (TLS + Caddy passthrough)"
            return 0
        fi
        sleep 10
    done
    fail "${label}: no marker from https://${fqdn} via ${ip} after retries"
    return 1
}

info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
info "${BOLD}║  Caddy public + split-horizon test: ${BL}${MODULE}${CL}"
info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

# ── Gate ─────────────────────────────────────────────────────────────
DEF_DOMAIN="$(get_variant_config "" 2>/dev/null | jq -r '.domain // ""')"
[[ -n "${DEF_DOMAIN}" && "${DEF_DOMAIN}" != CHANGE* ]] \
    || { warn "SKIP: no default-variant domain set (variant-manager add \"\" --domain <domain>)"; exit 0; }
FQDN="${MODULE}.${DEF_DOMAIN}"
PUBLIC_IP="$(dig +short @1.1.1.1 A "${FQDN}" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
is_public_ip "${PUBLIC_IP}" \
    || { warn "SKIP: public DNS for ${FQDN} did not resolve to a public IP (got '${PUBLIC_IP:-none}') — publish the A/wildcard record"; exit 0; }
DMZ_GW="$(dmz_gateway_ip 2>/dev/null || echo '')"
info "  FQDN:       ${BL}${FQDN}${CL}"
info "  Public IP:  ${BL}${PUBLIC_IP}${CL}"
info "  DMZ gw:     ${BL}${DMZ_GW:-?}${CL}"

# ── Provision (active zone — no zone/trunk changes) ──────────────────
info "${BOLD}Installing ${MODULE} in srvWork (already-active zone)...${CL}"
cd "${FIX}" || { fail "cannot cd ${FIX}"; exit 1; }
if /home/tappaas/bin/install-module.sh "${MODULE}"; then
    pass "install-module ${MODULE} succeeded"
else
    fail "install-module ${MODULE} failed — cannot test Caddy"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi

# ── (a) External passthrough via the public IP ───────────────────────
curl_marker "${FQDN}" "${PUBLIC_IP}" "external"

# ── (b) Split-horizon: internal DNS -> DMZ gateway, reachable via Caddy ─
INTERNAL_IP="$(getent hosts "${FQDN}" 2>/dev/null | awk '{print $1}' | head -1)"
if [[ -n "${DMZ_GW}" && "${INTERNAL_IP}" == "${DMZ_GW}" ]]; then
    pass "internal DNS resolves ${FQDN} -> ${DMZ_GW} (split-horizon)"
else
    fail "internal DNS for ${FQDN} is '${INTERNAL_IP:-none}', expected DMZ gateway '${DMZ_GW:-?}'"
fi
# Reach it the way an internal client would (system resolver -> DMZ gw), via Caddy.
curl_marker "${FQDN}" "${DMZ_GW:-${INTERNAL_IP}}" "internal"

# ── Summary ──────────────────────────────────────────────────────────
info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
