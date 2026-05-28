#!/usr/bin/env bash
#
# TAPPaaS Proxy Service - Install
#
# Configures the Caddy reverse proxy on OPNsense for a consuming module.
# Creates a domain entry and a reverse proxy handler via the caddy-manager CLI.
#
# When firewallType is "NONE" (no OPNsense deployed), this script prints
# the manual reverse proxy configuration the deployer needs to apply on
# their own firewall/proxy, then exits successfully.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
#
# The script reads the module JSON from /home/tappaas/config/<module>.json
# and configuration.json for default domain. It then:
#   1. Resolves proxyDomain (default: <vmname>.<tappaas.domain>)
#   2. Resolves proxyPort (default: 80)
#   3. Validates DNS for the proxy domain (warning only)
#   4. Creates a Caddy domain via caddy-manager
#   5. Creates a Caddy handler via caddy-manager
#   6. Reconfigures Caddy to apply changes
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=access-list.sh disable=SC1091
. "${SCRIPT_DIR}/access-list.sh"

info "firewall:proxy install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

if [[ ! -f "${SYSTEM_CONFIG}" ]]; then
    die "System configuration not found: ${SYSTEM_CONFIG}"
fi

# ── Read module configuration ───────────────────────────────────────

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv-home"' "${MODULE_JSON}")
TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")

if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    die "tappaas.domain not set in ${SYSTEM_CONFIG}"
fi

# Resolve proxyDomain: explicit in module JSON, or default to <vmname>.<domain>
PROXY_DOMAIN=$(jq -r '.proxyDomain // empty' "${MODULE_JSON}")
if [[ -z "${PROXY_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

# Resolve proxyPort: explicit in module JSON, or default to 80
PROXY_PORT=$(jq -r '.proxyPort // 80' "${MODULE_JSON}")

# Build upstream target
UPSTREAM="${VMNAME}.${ZONE}.internal"

# Description tag for idempotency
DESCRIPTION="TAPPaaS: ${MODULE}"

info "  Domain:   ${BL}${PROXY_DOMAIN}${CL}"
info "  Upstream: ${BL}${UPSTREAM}:${PROXY_PORT}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "The module '${MODULE}' requires a reverse proxy configuration."
    warn ""
    warn "${BOLD}Please configure the following on your firewall/reverse proxy:${CL}"
    warn "  ${BOLD}Domain:${CL}      ${BL}${PROXY_DOMAIN}${CL}"
    warn "  ${BOLD}Upstream:${CL}    ${BL}${UPSTREAM}${CL}"
    warn "  ${BOLD}Port:${CL}        ${BL}${PROXY_PORT}${CL}"
    warn "  ${BOLD}TLS:${CL}         Obtain a certificate for ${PROXY_DOMAIN}"
    warn "  ${BOLD}Rule:${CL}        Forward HTTPS traffic for ${PROXY_DOMAIN} → ${UPSTREAM}:${PROXY_PORT}"
    warn ""
    warn "Continuing without automated proxy setup."
    info "${GN}firewall:proxy install-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate caddy-manager ────────────────────────────────

if ! command -v caddy-manager &>/dev/null; then
    die "caddy-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── DNS validation (warning only) ───────────────────────────────────

if command -v dig &>/dev/null; then
    DNS_RESULT=$(dig +short A "${PROXY_DOMAIN}" 2>/dev/null || true)
    if [[ -z "${DNS_RESULT}" ]]; then
        warn "No DNS A record found for ${PROXY_DOMAIN}"
        warn "Let's Encrypt certificate issuance may fail until DNS is configured"
    else
        info "  DNS A:    ${BL}${DNS_RESULT}${CL}"
    fi
else
    warn "dig not available — skipping DNS validation"
fi

# ── TLS certificate strategy (proxyTls, default dns01) ──────────────

# proxyTls selects how this domain gets its public TLS cert (issue #254):
#   dns01 → bind the wildcard cert issued by os-acme-client (see acme-setup.sh)
#           via Caddy's per-domain CustomCertificate. Works for internal-only
#           services (no inbound HTTP-01 traffic needed) and shares one cert
#           across all dns01 modules. tappaas.tlsCertRefid must be populated
#           in configuration.json (acme-setup.sh does this).
#   http01 → Caddy issues a per-domain cert via ACME HTTP-01; the domain MUST
#            be reachable from the internet on :80. No DNS API needed.
PROXY_TLS=$(jq -r '.proxyTls // "dns01"' "${MODULE_JSON}")
CADDY_DOMAIN_ARGS=()
if [[ "${PROXY_TLS}" == "dns01" ]]; then
    TLS_CERT_REFID=$(jq -r '.tappaas.tlsCertRefid // ""' "${CONFIG_DIR}/configuration.json" 2>/dev/null)
    if [[ -n "${TLS_CERT_REFID}" ]]; then
        info "  TLS: DNS-01 wildcard (proxyTls=dns01) — refid ${TLS_CERT_REFID}"
        CADDY_DOMAIN_ARGS=(--custom-certificate "${TLS_CERT_REFID}")
    else
        warn "  TLS: proxyTls=dns01 but tappaas.tlsCertRefid is not set yet."
        warn "       The domain entry will be created; until acme-setup.sh runs,"
        warn "       the public HTTPS endpoint has no certificate (internal LAN access still works)."
    fi
else
    info "  TLS: HTTP-01 per-domain (proxyTls=${PROXY_TLS}) — Caddy will issue via ACME on :80"
fi

# ── Create domain ───────────────────────────────────────────────────

info "  Creating Caddy domain..."
caddy-manager add-domain "${PROXY_DOMAIN}" \
    --description "${DESCRIPTION}" \
    "${CADDY_DOMAIN_ARGS[@]+"${CADDY_DOMAIN_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to create Caddy domain"

# ── Resolve zone restriction → access list (issue #206) ─────────────

ACL_ARGS=()
if ! ACL_NAME=$(proxy_resolve_access_list "${MODULE}" "${MODULE_JSON}" "${ZONES_FILE}" "${DESCRIPTION}"); then
    die "Failed to resolve proxy access list for ${MODULE}"
fi
[[ -n "${ACL_NAME}" ]] && ACL_ARGS=(--access-list "${ACL_NAME}")

# HTTPS upstream (e.g. the OPNsense GUI on :8443).
TLS_ARGS=()
if [[ "$(jq -r '.proxyUpstreamTls // "false"' "${MODULE_JSON}")" == "true" ]]; then
    info "  Upstream is HTTPS (proxyUpstreamTls=true)"
    TLS_ARGS=(--upstream-tls)
fi

# ── Create handler ──────────────────────────────────────────────────

info "  Creating Caddy handler..."
caddy-manager add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
    "${TLS_ARGS[@]+"${TLS_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to create Caddy handler"

# ── Reconfigure Caddy ───────────────────────────────────────────────

info "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"

info "${GN}firewall:proxy install-service completed for ${MODULE}${CL}"
