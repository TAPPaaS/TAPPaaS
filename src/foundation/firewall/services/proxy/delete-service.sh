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

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
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
        VMNAME=$(get_config_value 'vmname' '')
        [[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"
        PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
        if [[ -z "${PROXY_DOMAIN}" ]]; then
            _V=$(get_config_value 'variant' '' 2>/dev/null || echo '')
            TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${_V}" 2>/dev/null || echo '{}')")
            [[ -z "${TAPPAAS_DOMAIN}" ]] && TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null)
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
    VMNAME=$(get_config_value 'vmname' '')
    if [[ -z "${VMNAME}" ]]; then
        VMNAME="${MODULE}"
    fi

    PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
    if [[ -z "${PROXY_DOMAIN}" ]]; then
        _V=$(get_config_value 'variant' '' 2>/dev/null || echo '')
        TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${_V}" 2>/dev/null || echo '{}')")
        if [[ -z "${TAPPAAS_DOMAIN}" ]] && [[ -f "${SYSTEM_CONFIG}" ]]; then
            TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null)
        fi
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

# ── Delete access list (issue #206) ─────────────────────────────────
# Remove the handler first so nothing references the access list, then drop it.
info "  Deleting Caddy access list (if any)..."
caddy-manager delete-accesslist "tappaas-${MODULE}" \
    --no-ssl-verify >/dev/null 2>&1 || true

# ── Delete domain ───────────────────────────────────────────────────

if [[ -n "${PROXY_DOMAIN}" ]]; then
    info "  Deleting Caddy domain: ${BL}${PROXY_DOMAIN}${CL}"
    caddy-manager delete-domain "${PROXY_DOMAIN}" \
        --no-ssl-verify || warn "Could not delete domain ${PROXY_DOMAIN}"

    # Per-service split-horizon DNS cleanup (ADR-005 §6, #269). Only per-service
    # mode created a per-module Dnsmasq entry; wildcard mode shares one entry
    # owned by acme-setup, so we must NOT remove that here. Deleting a
    # non-existent host is a harmless no-op.
    VARIANT=$(get_config_value 'variant' '' 2>/dev/null || echo '')
    VCFG="$(get_variant_config "${VARIANT}" 2>/dev/null || echo '{}')"
    if [[ "$(jq -r '.dnsMode // "wildcard"' <<<"${VCFG}")" == "per-service" ]]; then
        DNS_HOST="${PROXY_DOMAIN%%.*}"
        DNS_ZONE="${PROXY_DOMAIN#*.}"
        info "  Removing per-service Unbound override ${DNS_HOST}.${DNS_ZONE}..."
        unbound-manager --no-ssl-verify delete "${DNS_HOST}" "${DNS_ZONE}" >/dev/null 2>&1 \
            || warn "Could not remove Unbound override ${DNS_HOST}.${DNS_ZONE} (may not exist)"
    fi
else
    warn "Cannot determine proxy domain — manual cleanup may be needed"
fi

# ── Reconfigure Caddy ───────────────────────────────────────────────

info "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || warn "Caddy reconfigure returned non-zero"

info "${GN}firewall:proxy delete-service completed for ${MODULE}${CL}"
