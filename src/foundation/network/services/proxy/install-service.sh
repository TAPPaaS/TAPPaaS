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
# ADR-014 D-C4: prefer the EFFECTIVE zones document (zones.json with every
# `serves` link resolved) so a zone reachable only via its environment link
# still resolves to a CIDR here. Falls back to the authored file on a system
# that predates ADR-014 or has not rendered one yet.
# STALENESS GUARD: only trust the render while it is at least as new as the
# authored file. Anything writing zones.json outside network-manager (an operator
# hand-edit, or network/test.sh --deep merging its probe zones) leaves it behind,
# and resolving an allow-list against an out-of-date zone graph would silently
# produce the wrong CIDRs.
if [[ -f "${CONFIG_DIR}/zones.effective.json" \
      && ! "${CONFIG_DIR}/zones.json" -nt "${CONFIG_DIR}/zones.effective.json" ]]; then
    readonly ZONES_FILE="${CONFIG_DIR}/zones.effective.json"
else
    readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=access-list.sh disable=SC1091
. "${SCRIPT_DIR}/access-list.sh"

debug "network:proxy install-service for module: ${BL}${MODULE}${CL}"

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
# here against the module's environment so PROXY_DOMAIN defaulting works; the
# environment-specific read below (VCFG) reuses the same source for dnsMode/refid.
_ENV_EARLY=$(get_config_value 'environment' '')
TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"$(get_variant_config "${_ENV_EARLY}" 2>/dev/null || echo '{}')")
if [[ -z "${TAPPAAS_DOMAIN}" && -f "${SYSTEM_CONFIG}" ]]; then
    # Last-ditch legacy fallback: configuration.json is retired (ADR-007) and
    # ABSENT on a fresh install; guard with -f + `|| true` so a missing file
    # cannot abort under `set -e`.
    TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null) || TAPPAAS_DOMAIN=""
fi

# An environment with no domains.primary (e.g. mgmt, internal-only and reached
# at <vmname>.<zone>.internal) has no public name to publish — there is nothing
# to expose, so skip rather than fail the caller's module install. Before #438
# this was unreachable: the domain came from .variant, empty on foundation
# modules, so it fell back to the DEFAULT environment's domain. Reading
# .environment made "mgmt" explicit and turned this into a hard stop for every
# mgmt module depending on network:proxy.
if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    warn "No domain configured for environment '${_ENV_EARLY:-default}' — skipping reverse-proxy setup for '${MODULE}'"
    exit 0
fi

# Resolve proxyDomain: explicit in module JSON, or default to <vmname>.<domain>
PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
if [[ -z "${PROXY_DOMAIN}" && -n "${TAPPAAS_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

# Resolve proxyPort: explicit in module JSON, or default to 80
PROXY_PORT=$(get_config_value 'proxyPort' '80')

# Build upstream target
UPSTREAM="${VMNAME}.${ZONE}.internal"

# Description tag for idempotency
DESCRIPTION="TAPPaaS: ${MODULE}"

debug "  Domain:   ${BL}${PROXY_DOMAIN}${CL}"
debug "  Upstream: ${BL}${UPSTREAM}:${PROXY_PORT}${CL}"

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
    debug "${GN}network:proxy install-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate caddy-manager ────────────────────────────────

if ! command -v caddy-manager &>/dev/null; then
    die "caddy-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── DNS validation (warning only) ───────────────────────────────────

# Authoritative nameservers, not the local resolver — a split-horizon override
# for this name would otherwise satisfy the check (see public_a_record). This
# runs before DNS_MODE is resolved, so the message covers both strategies.
# `x="$(f)"` inherits f's exit status, which under `set -e` aborts the script
# the moment a domain has no public record — the very case this check exists to
# report (same hazard the jq guards above call out). Capture the code instead.
_dns_rc=0
DNS_RESULT="$(public_a_record "${PROXY_DOMAIN}")" || _dns_rc=$?
case "${_dns_rc}" in
    0) debug "  public DNS A: ${BL}${DNS_RESULT}${CL}" ;;
    1) warn "No PUBLIC DNS A record for ${PROXY_DOMAIN} (authoritative nameservers asked, not the local resolver)"
       warn "  under dnsMode=per-service ACME HTTP-01 cannot validate, so no certificate will issue" ;;
    *) debug "  public DNS A: not checked (no dig, or no resolver reachable)" ;;
esac

# ── TLS certificate strategy: variant dnsMode (ADR-005 §5/§6), proxyTls override ─

# The variant's dnsMode drives cert handling; an explicit per-module proxyTls
# (issue #254) overrides it (dns01->wildcard, http01->per-service):
#   wildcard    → bind the environment's wildcard cert (its .tlsCertRefid,
#                 issued by acme-setup.sh) via Caddy's per-domain CustomCertificate.
#                 The wildcard's split-horizon DNS is registered once by acme-setup.
#   per-service → no wildcard; register this module's own split-horizon DNS entry
#                 (<host>.<domain> -> DMZ gateway) and let Caddy issue a per-domain
#                 cert via ACME HTTP-01. No DNS API needed (#269, #289).
ENVIRONMENT=$(get_config_value 'environment' '')
VCFG="$(get_variant_config "${ENVIRONMENT}" 2>/dev/null || echo '{}')"
DNS_MODE="$(jq -r '.dnsMode // "per-service"' <<<"${VCFG}")"
ENV_REFID="$(jq -r '.tlsCertRefid // ""' <<<"${VCFG}")"

# Explicit proxyTls override (back-compat with #254).
PROXY_TLS=$(get_config_value 'proxyTls' '')
case "${PROXY_TLS}" in
    dns01)  DNS_MODE="wildcard" ;;
    http01) DNS_MODE="per-service" ;;
esac

CADDY_DOMAIN_ARGS=()
if [[ "${DNS_MODE}" == "per-service" ]]; then
    debug "  TLS: per-service HTTP-01 (dnsMode=per-service) — Caddy issues a cert for ${PROXY_DOMAIN}"
    # Split-horizon DNS must be an UNBOUND host override (the 10.0.0.1:53 resolver);
    # Dnsmasq host entries are not served for public domains (#269).
    if DMZ_GW="$(dmz_gateway_ip)"; then
        DNS_HOST="${PROXY_DOMAIN%%.*}"
        DNS_ZONE="${PROXY_DOMAIN#*.}"
        # A per-service override under a domain that already has a wildcard
        # "redirect" zone is FATAL to Unbound: a redirect zone permits local-data
        # only at the apex, so "<host>.<zone> IN A ..." fails unbound-checkconf and
        # stops the resolver — taking cluster DNS down (#474). This happens when a
        # module resolves dnsMode=per-service but publishes on a domain the default
        # environment serves via a wildcard. The wildcard already resolves
        # <host>.<zone> to the DMZ, so skip the colliding per-service entry.
        if unbound-manager --no-ssl-verify list 2>/dev/null \
             | awk -v z="${DNS_ZONE}" '$1=="*" && $2==z {f=1} END{exit !f}'; then
            debug "  ${GN}✓${CL} wildcard *.${DNS_ZONE} already covers ${DNS_HOST}.${DNS_ZONE} — skipping per-service override"
        elif unbound-manager --no-ssl-verify add "${DNS_HOST}" "${DNS_ZONE}" "${DMZ_GW}" --description "${DESCRIPTION}"; then
            debug "  ${GN}✓${CL} split-horizon DNS ${DNS_HOST}.${DNS_ZONE} -> ${DMZ_GW} (DMZ, Unbound)"
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
    TLS_CERT_REFID="${ENV_REFID}"
    if [[ -z "${TLS_CERT_REFID}" ]]; then
        _ENV_NAME="${ENVIRONMENT}"
        [[ -z "${_ENV_NAME}" ]] && _ENV_NAME="$(default_environment_name)"
        TLS_CERT_REFID="$(cert_refid_for_env "${_ENV_NAME}")"
    fi
    # Legacy fallback: configuration.json is retired (ADR-007) and ABSENT on a
    # fresh install; guard with -f + `|| true` so the missing file cannot abort
    # under `set -e` (was the fresh-install network:proxy install-service fatal).
    if [[ -z "${TLS_CERT_REFID}" && -f "${SYSTEM_CONFIG}" ]]; then
        TLS_CERT_REFID=$(jq -r '.tappaas.tlsCertRefid // ""' "${SYSTEM_CONFIG}" 2>/dev/null) || TLS_CERT_REFID=""
    fi
    if [[ -n "${TLS_CERT_REFID}" ]]; then
        debug "  TLS: DNS-01 wildcard (dnsMode=wildcard) — refid ${TLS_CERT_REFID}"
        CADDY_DOMAIN_ARGS=(--custom-certificate "${TLS_CERT_REFID}")
    else
        debug "  TLS: wildcard but no tlsCertRefid for environment '${ENVIRONMENT:-default}' yet."
        debug "       Run: acme-setup.sh --variant '${ENVIRONMENT}' (flag name unchanged; internal LAN access still works meanwhile)."
    fi
fi

# ── Create domain ───────────────────────────────────────────────────

debug "  Creating Caddy domain..."
run_caddy add-domain "${PROXY_DOMAIN}" \
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
    debug "  Upstream is HTTPS (proxyUpstreamTls=true)"
    TLS_ARGS=(--upstream-tls)
fi

# Force HTTP/1.1 to the upstream (os-caddy HttpVersion=http1). Needed for apps
# whose UI rides a WebSocket behind a TLS upstream (e.g. the UniFi OS console):
# Caddy otherwise negotiates HTTP/2 with the upstream, which cannot carry a
# WebSocket Upgrade and returns 500 — the SPA then renders blank. (#339)
HTTP1_ARGS=()
if [[ "$(get_config_value 'proxyUpstreamHttp1' 'false')" == "true" ]]; then
    debug "  Forcing HTTP/1.1 to the upstream (proxyUpstreamHttp1=true — WebSocket support)"
    HTTP1_ARGS=(--upstream-http1)
fi

# Preserve the original Host upstream (header_up Host <domain>). Needed for apps
# that validate a WebSocket's Origin against the Host header (e.g. UniFi OS):
# Caddy otherwise sends the upstream's own hostname, so Origin≠Host → 500. (#339)
PRESERVE_HOST_ARGS=()
if [[ "$(get_config_value 'proxyPreserveHost' 'false')" == "true" ]]; then
    debug "  Preserving Host upstream (proxyPreserveHost=true — WebSocket Origin check)"
    PRESERVE_HOST_ARGS=(--preserve-host)
fi

# ── Create handler ──────────────────────────────────────────────────

debug "  Creating Caddy handler..."
run_caddy add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
    "${TLS_ARGS[@]+"${TLS_ARGS[@]}"}" \
    "${HTTP1_ARGS[@]+"${HTTP1_ARGS[@]}"}" \
    "${PRESERVE_HOST_ARGS[@]+"${PRESERVE_HOST_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to create Caddy handler"

# ── Prune stale routes from a previous domain (#474) ────────────────
# Domains/handlers are keyed by DESCRIPTION (TAPPaaS: <module>). When the
# environment domain changes, the add-domain/add-handler above create the new
# <svc>.<newdomain> route but leave the old <svc>.<olddomain> orphaned (matched
# only by FQDN, so a re-run never revisits it). Remove any route with this
# module's description whose FQDN is not the current one. Idempotent no-op when
# the domain is unchanged.
debug "  Pruning stale reverse-proxy routes for ${MODULE}..."
run_caddy prune-domains --description "${DESCRIPTION}" --keep "${PROXY_DOMAIN}" \
    --no-ssl-verify || warn "Could not prune stale Caddy routes for ${MODULE} (non-fatal)"

# ── Reconfigure Caddy ───────────────────────────────────────────────

debug "  Applying Caddy configuration..."
run_caddy reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"

debug "${GN}network:proxy install-service completed for ${MODULE}${CL}"
