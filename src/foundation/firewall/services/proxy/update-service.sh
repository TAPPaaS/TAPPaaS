#!/usr/bin/env bash
#
# TAPPaaS Proxy Service - Update
#
# Validates and updates the Caddy reverse proxy configuration for a
# consuming module. If the domain or handler is missing, it creates them.
# If the handler configuration has changed, it deletes and recreates it.
#
# When firewallType is "NONE", prints manual configuration reminder.
#
# Usage: update-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'
readonly BOLD=$'\033[1m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info "firewall:proxy update-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

if [[ ! -f "${SYSTEM_CONFIG}" ]]; then
    die "System configuration not found: ${SYSTEM_CONFIG}"
fi

# ── Read expected configuration ─────────────────────────────────────

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")

if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    die "tappaas.domain not set in ${SYSTEM_CONFIG}"
fi

PROXY_DOMAIN=$(jq -r '.proxyDomain // empty' "${MODULE_JSON}")
if [[ -z "${PROXY_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

PROXY_PORT=$(jq -r '.proxyPort // 80' "${MODULE_JSON}")
UPSTREAM="${VMNAME}.${ZONE}.internal"
DESCRIPTION="TAPPaaS: ${MODULE}"

info "  Expected domain:   ${BL}${PROXY_DOMAIN}${CL}"
info "  Expected upstream: ${BL}${UPSTREAM}:${PROXY_PORT}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "Ensure your reverse proxy is configured for module '${MODULE}':"
    warn "  ${BOLD}Domain:${CL}      ${BL}${PROXY_DOMAIN}${CL}"
    warn "  ${BOLD}Upstream:${CL}    ${BL}${UPSTREAM}${CL}"
    warn "  ${BOLD}Port:${CL}        ${BL}${PROXY_PORT}${CL}"
    info "${GN}firewall:proxy update-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate caddy-manager ────────────────────────────────

if ! command -v caddy-manager &>/dev/null; then
    die "caddy-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Check current state ─────────────────────────────────────────────

# Capture caddy-manager list output for parsing
LIST_OUTPUT=$(caddy-manager list --no-ssl-verify 2>&1) || true

CHANGES_MADE=false

# Check if domain exists (by looking for it in the list output)
if echo "${LIST_OUTPUT}" | grep -q "${PROXY_DOMAIN}"; then
    info "  Domain ${PROXY_DOMAIN} exists"
else
    warn "Domain ${PROXY_DOMAIN} missing — creating..."
    caddy-manager add-domain "${PROXY_DOMAIN}" \
        --description "${DESCRIPTION}" \
        --no-ssl-verify || die "Failed to create Caddy domain"
    CHANGES_MADE=true
fi

# Check if handler exists with correct description
if echo "${LIST_OUTPUT}" | grep -q "${DESCRIPTION}"; then
    info "  Handler '${DESCRIPTION}' exists"

    # Verify upstream and port match expected values
    if echo "${LIST_OUTPUT}" | grep "${DESCRIPTION}" | grep -q "${UPSTREAM}:${PROXY_PORT}"; then
        info "  Handler configuration matches — no changes needed"
    else
        warn "Handler configuration differs — recreating..."
        caddy-manager delete-handler \
            --description "${DESCRIPTION}" \
            --no-ssl-verify || warn "Could not delete old handler"
        caddy-manager add-handler "${PROXY_DOMAIN}" \
            --upstream "${UPSTREAM}" \
            --port "${PROXY_PORT}" \
            --description "${DESCRIPTION}" \
            --no-ssl-verify || die "Failed to create Caddy handler"
        CHANGES_MADE=true
    fi
else
    warn "Handler '${DESCRIPTION}' missing — creating..."
    caddy-manager add-handler "${PROXY_DOMAIN}" \
        --upstream "${UPSTREAM}" \
        --port "${PROXY_PORT}" \
        --description "${DESCRIPTION}" \
        --no-ssl-verify || die "Failed to create Caddy handler"
    CHANGES_MADE=true
fi

# ── Reconfigure if changes were made ────────────────────────────────

if [[ "${CHANGES_MADE}" == "true" ]]; then
    info "  Applying Caddy configuration..."
    caddy-manager reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"
fi

# ── DNS validation (warning only) ───────────────────────────────────

if command -v dig &>/dev/null; then
    DNS_RESULT=$(dig +short A "${PROXY_DOMAIN}" 2>/dev/null || true)
    if [[ -z "${DNS_RESULT}" ]]; then
        warn "No DNS A record found for ${PROXY_DOMAIN}"
    fi
fi

info "${GN}firewall:proxy update-service completed for ${MODULE}${CL}"
