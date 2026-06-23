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
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=access-list.sh disable=SC1091
. "${SCRIPT_DIR}/access-list.sh"

info "network:proxy install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ADR-007: configuration.json is retired. The domain comes from get_variant_config
# (config/environments/) and the cert refid from cert-refids.json; the SYSTEM_CONFIG
# reads below are guarded legacy fallbacks, so its absence is NOT fatal.

# ── Read module configuration ───────────────────────────────────────

VMNAME=$(get_config_value 'vmname' '')
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(get_config_value 'zone0' 'srvHome')
# Domain comes from the module's environment (variant); get_variant_config reads
# config/environments/<env>.json and falls back to configuration.json. Read it
# here against the module's variant so PROXY_DOMAIN defaulting works; the
# variant-specific read below (VCFG) reuses the same source for dnsMode/refid.
_VARIANT_EARLY=$(get_config_value 'variant' '')
TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${_VARIANT_EARLY}" 2>/dev/null || echo '{}')")
if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    # Last-ditch legacy fallback (kept until configuration.json is deleted).
    TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null)
fi

if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    die "No domain resolved for environment '${_VARIANT_EARLY:-default}' (config/environments/ or configuration.json)"
fi

# Resolve proxyDomain: explicit in module JSON, or default to <vmname>.<domain>
PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
if [[ -z "${PROXY_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

# Resolve proxyPort: explicit in module JSON, or default to 80
PROXY_PORT=$(get_config_value 'proxyPort' '80')

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
    info "${GN}network:proxy install-service completed for ${MODULE} (manual config required)${CL}"
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

# ── TLS certificate strategy: variant dnsMode (ADR-005 §5/§6), proxyTls override ─

# The variant's dnsMode drives cert handling; an explicit per-module proxyTls
# (issue #254) overrides it (dns01->wildcard, http01->per-service):
#   wildcard    → bind the variant's wildcard cert (variants[<v>].tlsCertRefid,
#                 issued by acme-setup.sh) via Caddy's per-domain CustomCertificate.
#                 The wildcard's split-horizon DNS is registered once by acme-setup.
#   per-service → no wildcard; register this module's own split-horizon DNS entry
#                 (<host>.<domain> -> DMZ gateway) and let Caddy issue a per-domain
#                 cert via ACME HTTP-01. No DNS API needed (#269, #289).
VARIANT=$(get_config_value 'variant' '')
VCFG="$(get_variant_config "${VARIANT}" 2>/dev/null || echo '{}')"
DNS_MODE="$(jq -r '.dnsMode // "wildcard"' <<<"${VCFG}")"
VARIANT_REFID="$(jq -r '.tlsCertRefid // ""' <<<"${VCFG}")"

# Explicit proxyTls override (back-compat with #254).
PROXY_TLS=$(get_config_value 'proxyTls' '')
case "${PROXY_TLS}" in
    dns01)  DNS_MODE="wildcard" ;;
    http01) DNS_MODE="per-service" ;;
esac

CADDY_DOMAIN_ARGS=()
if [[ "${DNS_MODE}" == "per-service" ]]; then
    info "  TLS: per-service HTTP-01 (dnsMode=per-service) — Caddy issues a cert for ${PROXY_DOMAIN}"
    # Split-horizon DNS must be an UNBOUND host override (the 10.0.0.1:53 resolver);
    # Dnsmasq host entries are not served for public domains (#269).
    if DMZ_GW="$(dmz_gateway_ip)"; then
        DNS_HOST="${PROXY_DOMAIN%%.*}"
        DNS_ZONE="${PROXY_DOMAIN#*.}"
        if unbound-manager --no-ssl-verify add "${DNS_HOST}" "${DNS_ZONE}" "${DMZ_GW}" --description "${DESCRIPTION}"; then
            info "  ${GN}✓${CL} split-horizon DNS ${DNS_HOST}.${DNS_ZONE} -> ${DMZ_GW} (DMZ, Unbound)"
        else
            warn "  Could not register ${PROXY_DOMAIN} in Unbound — register manually:"
            warn "    unbound-manager --no-ssl-verify add '${DNS_HOST}' '${DNS_ZONE}' '${DMZ_GW}'"
        fi
    else
        warn "  Could not derive DMZ gateway — register ${PROXY_DOMAIN} DNS manually"
    fi
else
    # wildcard: prefer the variant's refid (sourced from cert-refids.json via
    # get_variant_config), then the runtime cert-refids.json for the env, then
    # the legacy global one in configuration.json.
    TLS_CERT_REFID="${VARIANT_REFID}"
    if [[ -z "${TLS_CERT_REFID}" ]]; then
        _ENV_NAME="${VARIANT}"
        [[ -z "${_ENV_NAME}" ]] && _ENV_NAME="$(default_environment_name)"
        TLS_CERT_REFID="$(cert_refid_for_env "${_ENV_NAME}")"
    fi
    [[ -z "${TLS_CERT_REFID}" ]] && TLS_CERT_REFID=$(jq -r '.tappaas.tlsCertRefid // ""' "${SYSTEM_CONFIG}" 2>/dev/null)
    if [[ -n "${TLS_CERT_REFID}" ]]; then
        info "  TLS: DNS-01 wildcard (dnsMode=wildcard) — refid ${TLS_CERT_REFID}"
        CADDY_DOMAIN_ARGS=(--custom-certificate "${TLS_CERT_REFID}")
    else
        warn "  TLS: wildcard but no tlsCertRefid for variant '${VARIANT:-default}' yet."
        warn "       Run: acme-setup.sh --variant '${VARIANT}' (internal LAN access still works meanwhile)."
    fi
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
if [[ "$(get_config_value 'proxyUpstreamTls' 'false')" == "true" ]]; then
    info "  Upstream is HTTPS (proxyUpstreamTls=true)"
    TLS_ARGS=(--upstream-tls)
fi

# Force HTTP/1.1 to the upstream (os-caddy HttpVersion=http1). Needed for apps
# whose UI rides a WebSocket behind a TLS upstream (e.g. the UniFi OS console):
# Caddy otherwise negotiates HTTP/2 with the upstream, which cannot carry a
# WebSocket Upgrade and returns 500 — the SPA then renders blank. (#339)
HTTP1_ARGS=()
if [[ "$(get_config_value 'proxyUpstreamHttp1' 'false')" == "true" ]]; then
    info "  Forcing HTTP/1.1 to the upstream (proxyUpstreamHttp1=true — WebSocket support)"
    HTTP1_ARGS=(--upstream-http1)
fi

# Preserve the original Host upstream (header_up Host <domain>). Needed for apps
# that validate a WebSocket's Origin against the Host header (e.g. UniFi OS):
# Caddy otherwise sends the upstream's own hostname, so Origin≠Host → 500. (#339)
PRESERVE_HOST_ARGS=()
if [[ "$(get_config_value 'proxyPreserveHost' 'false')" == "true" ]]; then
    info "  Preserving Host upstream (proxyPreserveHost=true — WebSocket Origin check)"
    PRESERVE_HOST_ARGS=(--preserve-host)
fi

# ── Create handler ──────────────────────────────────────────────────

info "  Creating Caddy handler..."
caddy-manager add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
    "${TLS_ARGS[@]+"${TLS_ARGS[@]}"}" \
    "${HTTP1_ARGS[@]+"${HTTP1_ARGS[@]}"}" \
    "${PRESERVE_HOST_ARGS[@]+"${PRESERVE_HOST_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to create Caddy handler"

# ── Reconfigure Caddy ───────────────────────────────────────────────

info "  Applying Caddy configuration..."
caddy-manager reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"

info "${GN}network:proxy install-service completed for ${MODULE}${CL}"
