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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=access-list.sh disable=SC1091
. "${SCRIPT_DIR}/access-list.sh"

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi

debug "network:proxy delete-service for module: ${BL}${MODULE}${CL}"

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
        # The one derivation (#715), so the reminder names the route install made.
        PROXY_DOMAIN="$(module_public_domain "${VMNAME}" \
            "$(get_config_value 'environment' '' 2>/dev/null || echo '')" "${JSON}")"
    fi

    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    if [[ -n "${PROXY_DOMAIN}" ]]; then
        warn "Remember to remove the reverse proxy rule for ${BL}${PROXY_DOMAIN}${CL} from your firewall."
    else
        warn "Remember to remove any reverse proxy rules for module '${MODULE}' from your firewall."
    fi
    debug "${GN}network:proxy delete-service completed for ${MODULE} (manual cleanup required)${CL}"
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
TAPPAAS_DOMAIN=""
if [[ -f "${MODULE_JSON}" ]]; then
    VMNAME=$(get_config_value 'vmname' '')
    if [[ -z "${VMNAME}" ]]; then
        VMNAME="${MODULE}"
    fi

    # The environment's primary domain — needed both for the default proxyDomain
    # and (independent of proxyDomain) as the suffix of every proxyRoutes FQDN.
    _ENV=$(get_config_value 'environment' '' 2>/dev/null || echo '')
    TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${_ENV}" 2>/dev/null || echo '{}')")
    if [[ -z "${TAPPAAS_DOMAIN}" ]] && [[ -f "${SYSTEM_CONFIG}" ]]; then
        TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null) || TAPPAAS_DOMAIN=""
    fi

    # The one derivation, shared with install-service (#715): update, test and
    # delete must name exactly what install published, or they act on another route.
    PROXY_DOMAIN="$(module_public_domain "${VMNAME}" "${_ENV:-}" "${JSON}")"
fi

DESCRIPTION="TAPPaaS: ${MODULE}"

# ── Remove everything the module published (handler, access list, domain,
#    extra proxyRoutes, split-horizon records) — the one removal path, shared
#    with install/update withdrawing an unpublished module (#778) ───────────
debug "  Removing ${MODULE}'s reverse-proxy routes${PROXY_DOMAIN:+ (${BL}${PROXY_DOMAIN}${CL})}..."
proxy_unpublish "${MODULE}" "${PROXY_DOMAIN}" "${TAPPAAS_DOMAIN}" "$([[ -f "${MODULE_JSON}" ]] && echo "${JSON}")"

# ── Reconfigure Caddy ───────────────────────────────────────────────

debug "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || warn "Caddy reconfigure returned non-zero"

debug "${GN}network:proxy delete-service completed for ${MODULE}${CL}"
