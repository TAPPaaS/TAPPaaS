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

debug "network:proxy update-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ADR-007: configuration.json is retired. The domain comes from get_variant_config
# (config/environments/) and the cert refid from cert-refids.json; the SYSTEM_CONFIG
# reads below are guarded legacy fallbacks, so its absence is NOT fatal.

# ── Read expected configuration ─────────────────────────────────────

VMNAME=$(get_config_value 'vmname' '')
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(get_config_value 'zone0' 'srvHome')
# Domain from the module's environment (config/environments/<env>.json via
# get_variant_config), falling back to legacy configuration.json .tappaas.domain.
ENVIRONMENT=$(get_config_value 'environment' '')
VCFG="$(get_variant_config "${ENVIRONMENT}" 2>/dev/null || echo '{}')"
TAPPAAS_DOMAIN=$(jq -r '.domain // empty' <<<"${VCFG}")
# Legacy fallback: configuration.json is retired (ADR-007) and ABSENT on a fresh
# install; guard the read with -f + `|| true` so a missing file cannot abort the
# script under `set -e` (a bare `x=$(jq missing-file)` inherits jq's exit 2).
if [[ -z "${TAPPAAS_DOMAIN}" && -f "${SYSTEM_CONFIG}" ]]; then
    TAPPAAS_DOMAIN=$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}" 2>/dev/null) || TAPPAAS_DOMAIN=""
fi

# An environment with no domains.primary (e.g. mgmt, internal-only and reached
# at <vmname>.<zone>.internal) has no public name to publish — there is nothing
# to reconcile, so skip rather than fail the caller's module update. Before #438
# this was unreachable: the domain came from .variant, empty on foundation
# modules, so it fell back to the DEFAULT environment's domain. Reading
# .environment made "mgmt" explicit and turned this into a hard stop for every
# mgmt module depending on network:proxy.
if [[ -z "${TAPPAAS_DOMAIN}" ]]; then
    warn "No domain configured for environment '${ENVIRONMENT:-default}' — skipping reverse-proxy reconcile for '${MODULE}'"
    exit 0
fi

PROXY_DOMAIN=$(get_config_value 'proxyDomain' '')
if [[ -z "${PROXY_DOMAIN}" && -n "${TAPPAAS_DOMAIN}" ]]; then
    PROXY_DOMAIN="${VMNAME}.${TAPPAAS_DOMAIN}"
fi

PROXY_PORT=$(get_config_value 'proxyPort' '80')
UPSTREAM="${VMNAME}.${ZONE}.internal"
DESCRIPTION="TAPPaaS: ${MODULE}"

debug "  Expected domain:   ${BL}${PROXY_DOMAIN}${CL}"
debug "  Expected upstream: ${BL}${UPSTREAM}:${PROXY_PORT}${CL}"

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
    debug "${GN}network:proxy update-service completed for ${MODULE} (manual config required)${CL}"
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

# TLS strategy: the environment's dnsMode is the base and an explicit per-module
# proxyTls (issue #254) overrides it — the SAME precedence install-service.sh
# uses. This block previously defaulted proxyTls to "dns01" and never consulted
# dnsMode, so install and update disagreed on every per-service environment:
# install issued an HTTP-01 cert and registered split-horizon DNS, then the next
# update reconciled the same domain as a wildcard against a refid that does not
# exist — leaving a published domain with no usable certificate.
#   wildcard    → bind the environment's wildcard cert via CustomCertificate.
#   per-service → Caddy issues per-domain via ACME HTTP-01 (needs the domain
#                 publicly reachable on :80) + a split-horizon Unbound override.
DNS_MODE="$(jq -r '.dnsMode // "per-service"' <<<"${VCFG}")"
PROXY_TLS=$(get_config_value 'proxyTls' '')
case "${PROXY_TLS}" in
    dns01)  DNS_MODE="wildcard" ;;
    http01) DNS_MODE="per-service" ;;
esac

CADDY_DOMAIN_ARGS=()
if [[ "${DNS_MODE}" == "per-service" ]]; then
    debug "  TLS: per-service HTTP-01 (dnsMode=per-service) — Caddy issues a cert for ${PROXY_DOMAIN}"
    # Reconcile the split-horizon override as well. install-service.sh creates
    # it, but only update runs against an already-installed module, so without
    # this a record that was deleted — or never created, as for every module
    # installed before #438 — is never restored.
    if DMZ_GW="$(dmz_gateway_ip)"; then
        DNS_HOST="${PROXY_DOMAIN%%.*}"
        DNS_ZONE="${PROXY_DOMAIN#*.}"
        # A per-service override under a domain that already has a wildcard
        # "redirect" zone is FATAL to Unbound (#474): a redirect zone permits
        # local-data only at the apex, so "<host>.<zone> IN A ..." fails
        # unbound-checkconf and stops the resolver — taking cluster DNS down.
        # The wildcard already resolves <host>.<zone> to the DMZ, so skip the
        # colliding per-service entry. Mirrors the guard in install-service.sh.
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
    # Prefer the env's refid from get_variant_config (cert-refids.json), then the
    # runtime cert-refids.json directly, then the legacy global configuration.json.
    TLS_CERT_REFID=$(jq -r '.tlsCertRefid // ""' <<<"${VCFG}")
    if [[ -z "${TLS_CERT_REFID}" ]]; then
        _ENV_NAME="${ENVIRONMENT}"
        [[ -z "${_ENV_NAME}" ]] && _ENV_NAME="$(default_environment_name)"
        TLS_CERT_REFID="$(cert_refid_for_env "${_ENV_NAME}")"
    fi
    # Legacy fallback: configuration.json is retired (ADR-007) and ABSENT on a
    # fresh install; guard with -f + `|| true` so the missing file cannot abort
    # under `set -e` (the culprit for the fresh-install "network:proxy" fatal).
    if [[ -z "${TLS_CERT_REFID}" && -f "${CONFIG_DIR}/configuration.json" ]]; then
        TLS_CERT_REFID=$(jq -r '.tappaas.tlsCertRefid // ""' "${CONFIG_DIR}/configuration.json" 2>/dev/null) || TLS_CERT_REFID=""
    fi
    if [[ -n "${TLS_CERT_REFID}" ]]; then
        debug "  TLS: DNS-01 wildcard (dnsMode=wildcard) — refid ${TLS_CERT_REFID}"
        CADDY_DOMAIN_ARGS=(--custom-certificate "${TLS_CERT_REFID}")
    else
        debug "  TLS: wildcard but no tlsCertRefid for environment '${ENVIRONMENT:-default}' yet."
        debug "       Run: acme-setup.sh --variant '${ENVIRONMENT}' — internal LAN access still works meanwhile."
    fi
fi

# Reconcile the domain (creates if missing, applies the TLS strategy either way)
debug "  Reconciling domain ${PROXY_DOMAIN} (TLS=${PROXY_TLS})..."
run_caddy add-domain "${PROXY_DOMAIN}" \
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

debug "  Reconciling handler (upstream ${UPSTREAM}:${PROXY_PORT}, access=${ACL_NAME:-public})..."
run_caddy add-handler "${PROXY_DOMAIN}" \
    --upstream "${UPSTREAM}" \
    --port "${PROXY_PORT}" \
    --description "${DESCRIPTION}" \
    "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
    "${TLS_ARGS[@]+"${TLS_ARGS[@]}"}" \
    --no-ssl-verify || die "Failed to reconcile Caddy handler"
CHANGES_MADE=true

# ── Reconfigure if changes were made ────────────────────────────────

if [[ "${CHANGES_MADE}" == "true" ]]; then
    debug "  Applying Caddy configuration..."
    run_caddy reconfigure --no-ssl-verify || die "Failed to reconfigure Caddy"
fi

# ── DNS validation (warning only) ───────────────────────────────────

# Checked against the zone's authoritative nameservers, NOT the local resolver:
# under per-service we register a split-horizon override for this very name a
# few lines above, so a local lookup would answer with our own record and this
# check could never fail (see public_a_record).
# `x="$(f)"` inherits f's exit status, which under `set -e` aborts the script
# the moment a domain has no public record — the very case this check exists to
# report (same hazard the jq guards above call out). Capture the code instead.
_dns_rc=0
DNS_RESULT="$(public_a_record "${PROXY_DOMAIN}")" || _dns_rc=$?
case "${_dns_rc}" in
    0) debug "  public DNS A: ${BL}${DNS_RESULT}${CL}" ;;
    1) warn "No PUBLIC DNS A record for ${PROXY_DOMAIN} (authoritative nameservers asked, not the local resolver)"
       if [[ "${DNS_MODE}" == "per-service" ]]; then
           warn "  ACME HTTP-01 cannot validate it, so this domain gets no certificate until a public A record exists"
       else
           warn "  the wildcard certificate is unaffected, but the name is not reachable from the internet"
       fi ;;
    *) debug "  public DNS A: not checked (no dig, or no resolver reachable)" ;;
esac

debug "${GN}network:proxy update-service completed for ${MODULE}${CL}"
