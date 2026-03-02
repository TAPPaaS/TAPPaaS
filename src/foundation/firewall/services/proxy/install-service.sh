#!/usr/bin/env bash
#
# TAPPaaS Proxy Service - Install
#
# Configures the Caddy reverse proxy on OPNsense for a consuming module.
# Creates a domain entry and a reverse proxy handler via the caddy-manager CLI.
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

readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"

info "firewall:proxy install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

if [[ ! -f "${SYSTEM_CONFIG}" ]]; then
    die "System configuration not found: ${SYSTEM_CONFIG}"
fi

if ! command -v caddy-manager &>/dev/null; then
    die "caddy-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Read module configuration ───────────────────────────────────────

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
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

# ── Create domain ───────────────────────────────────────────────────

info "  Creating Caddy domain..."
caddy-manager add-domain "${PROXY_DOMAIN}" \
    --description "${DESCRIPTION}" \
    --no-ssl-verify || die "Failed to create Caddy domain"

# ── Create handler ──────────────────────────────────────────────────

info "  Creating Caddy handler..."
caddy-manager add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    --no-ssl-verify || die "Failed to create Caddy handler"

# ── Reconfigure Caddy ───────────────────────────────────────────────

info "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"

info "${GN}firewall:proxy install-service completed for ${MODULE}${CL}"
