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

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=access-list.sh disable=SC1091
. "${SCRIPT_DIR}/access-list.sh"

info "firewall:proxy update-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

if [[ ! -f "${SYSTEM_CONFIG}" ]]; then
    die "System configuration not found: ${SYSTEM_CONFIG}"
fi

# ── Read expected configuration ─────────────────────────────────────

VMNAME=$(get_config_value 'vmname' '')
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(get_config_value 'zone0' 'srv-home')
TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")

if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    die "tappaas.domain not set in ${SYSTEM_CONFIG}"
fi

PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
if [[ -z "${PROXY_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

PROXY_PORT=$(get_config_value 'proxyPort' '80')
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

# proxyTls (issue #254): dns01 = bind the os-acme-client wildcard via Caddy's
# CustomCertificate refid; http01 = let Caddy issue per-domain via ACME HTTP-01
# (requires the domain be publicly reachable on :80). Either reconciles in place.
PROXY_TLS=$(get_config_value 'proxyTls' 'dns01')
CADDY_DOMAIN_ARGS=()
if [[ "${PROXY_TLS}" == "dns01" ]]; then
    TLS_CERT_REFID=$(jq -r '.tappaas.tlsCertRefid // ""' "${CONFIG_DIR}/configuration.json" 2>/dev/null)
    if [[ -n "${TLS_CERT_REFID}" ]]; then
        CADDY_DOMAIN_ARGS=(--custom-certificate "${TLS_CERT_REFID}")
    else
        warn "  proxyTls=dns01 but tappaas.tlsCertRefid not set (run acme-setup.sh) — public TLS unavailable until then"
    fi
fi

# Reconcile the domain (creates if missing, applies the TLS strategy either way)
info "  Reconciling domain ${PROXY_DOMAIN} (TLS=${PROXY_TLS})..."
caddy-manager add-domain "${PROXY_DOMAIN}" \
    --description "${DESCRIPTION}" \
    "${CADDY_DOMAIN_ARGS[@]+"${CADDY_DOMAIN_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to reconcile Caddy domain"
CHANGES_MADE=true

# Resolve the zone restriction → access list (issue #206), then reconcile the
# handler. add-handler updates an existing handler in place, so this also
# (re)applies the access list and any upstream/port change in one step.
ACL_ARGS=()
if ! ACL_NAME=$(proxy_resolve_access_list "${MODULE}" "${MODULE_JSON}" "${ZONES_FILE}" "${DESCRIPTION}"); then
    die "Failed to resolve proxy access list for ${MODULE}"
fi
[[ -n "${ACL_NAME}" ]] && ACL_ARGS=(--access-list "${ACL_NAME}")

TLS_ARGS=()
if [[ "$(get_config_value 'proxyUpstreamTls' 'false')" == "true" ]]; then
    TLS_ARGS=(--upstream-tls)
fi

info "  Reconciling handler (upstream ${UPSTREAM}:${PROXY_PORT}, access=${ACL_NAME:-public})..."
caddy-manager add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
    "${TLS_ARGS[@]+"${TLS_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to reconcile Caddy handler"
CHANGES_MADE=true

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
