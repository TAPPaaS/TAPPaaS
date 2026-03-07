#!/usr/bin/env bash
#
# TAPPaaS Proxy Service - Delete
#
# Removes the Caddy reverse proxy configuration for a consuming module.
# Deletes the handler and domain entry via the caddy-manager CLI.
#
# When firewallType is "NONE", prints a reminder to clean up manual config.
#
# Usage: delete-service.sh <module-name>
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
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:proxy delete-service for module: ${BL}${MODULE}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    # Resolve proxy domain for the reminder message
    PROXY_DOMAIN=""
    if [[ -f "${MODULE_JSON}" ]] && [[ -f "${SYSTEM_CONFIG}" ]]; then
        VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
        [[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"
        PROXY_DOMAIN=$(jq -r '.proxyDomain // empty' "${MODULE_JSON}")
        if [[ -z "${PROXY_DOMAIN}" ]]; then
            TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")
            [[ -n "${TAPPAAS_DOMAIN}" ]] && PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
        fi
    fi

    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    if [[ -n "${PROXY_DOMAIN}" ]]; then
        warn "Remember to remove the reverse proxy rule for ${BL}${PROXY_DOMAIN}${CL} from your firewall."
    else
        warn "Remember to remove any reverse proxy rules for module '${MODULE}' from your firewall."
    fi
    info "${GN}firewall:proxy delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

# ── OPNsense: validate caddy-manager ────────────────────────────────

if ! command -v caddy-manager &>/dev/null; then
    die "caddy-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    warn "Module config not found: ${MODULE_JSON} — attempting cleanup by description"
fi

# ── Resolve proxy domain ────────────────────────────────────────────

PROXY_DOMAIN=""
if [[ -f "${MODULE_JSON}" ]]; then
    VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
    if [[ -z "${VMNAME}" ]]; then
        VMNAME="${MODULE}"
    fi

    PROXY_DOMAIN=$(jq -r '.proxyDomain // empty' "${MODULE_JSON}")
    if [[ -z "${PROXY_DOMAIN}" ]] && [[ -f "${SYSTEM_CONFIG}" ]]; then
        TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")
        if [[ -n "${TAPPAAS_DOMAIN}" ]]; then
            PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
        fi
    fi
fi

DESCRIPTION="TAPPaaS: ${MODULE}"

# ── Delete handler ──────────────────────────────────────────────────

info "  Deleting Caddy handler..."
caddy-manager delete-handler \
    --description "${DESCRIPTION}" \
    --no-ssl-verify || warn "Could not delete handler for ${MODULE}"

# ── Delete domain ───────────────────────────────────────────────────

if [[ -n "${PROXY_DOMAIN}" ]]; then
    info "  Deleting Caddy domain: ${BL}${PROXY_DOMAIN}${CL}"
    caddy-manager delete-domain "${PROXY_DOMAIN}" \
        --no-ssl-verify || warn "Could not delete domain ${PROXY_DOMAIN}"
else
    warn "Cannot determine proxy domain — manual cleanup may be needed"
fi

# ── Reconfigure Caddy ───────────────────────────────────────────────

info "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || warn "Caddy reconfigure returned non-zero"

info "${GN}firewall:proxy delete-service completed for ${MODULE}${CL}"
