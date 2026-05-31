#!/usr/bin/env bash
#
# TAPPaaS DNS Service - Install
#
# Creates an OPNsense DNS host override resolving <vmname>.<zone0>.internal to a
# static IP (the module's `ip` field) via the dns-manager CLI. This lets hardware
# modules (no VM — firewall rules + a known static device IP only) provision
# their DNS entry at install time instead of requiring a manual dns-manager
# prerequisite. See #251.
#
# The hostname is NOT a parameter: it is always <vmname>.<zone0>.internal
# (Lars, #251). Only the IP is supplied via the module's `ip` field — required,
# no default, overridable at install time with --ip <addr>.
#
# When firewallType is "NONE" (no OPNsense deployed), this script prints the
# manual DNS entry the deployer must create, then exits successfully.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., alfen)
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:dns install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ── Resolve hostname (vmname) and domain (<zone0>.internal) ─────────

VMNAME=$(get_config_value 'vmname' '')
if [[ -z "${VMNAME}" ]]; then
    VMNAME="${MODULE}"
fi

ZONE=$(get_config_value 'zone0' '')
if [[ -z "${ZONE}" ]]; then
    die "zone0 not set for ${MODULE} — required to build the DNS domain (<zone0>.internal)"
fi
DOMAIN="${ZONE}.internal"

# ── Resolve the static IP (ip) — required, no default (Lars #3) ──────

DNS_IP=$(get_config_value 'ip' '')
if [[ -z "${DNS_IP}" || "${DNS_IP}" == "null" ]]; then
    die "ip not set for ${MODULE} — pass --ip <addr> or set config.\"firewall:dns\".ip in ${MODULE}.json"
fi

DESCRIPTION="TAPPaaS: ${MODULE}"

info "  Host: ${BL}${VMNAME}.${DOMAIN}${CL} -> ${BL}${DNS_IP}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "The module '${MODULE}' needs the following DNS host override:"
    warn "  ${BOLD}Hostname:${CL} ${BL}${VMNAME}.${DOMAIN}${CL}"
    warn "  ${BOLD}IP:${CL}       ${BL}${DNS_IP}${CL}"
    warn "Create this entry on your DNS server, then continue."
    info "${GN}firewall:dns install-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate dns-manager ──────────────────────────────────

if ! command -v dns-manager &>/dev/null; then
    die "dns-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── DHCP-pool sanity check (warning only) — Lars #4, issue #251 ──────
# A static DNS override should point at a reservation OUTSIDE the zone's DHCP
# pool, otherwise dnsmasq may hand the same address to another client.
# check-range exits non-zero when the IP is inside a pool; we only warn.
if ! dns-manager --no-ssl-verify check-range "${DNS_IP}"; then
    warn "  ${DNS_IP} appears to be inside a DHCP pool — a static reservation should be OUTSIDE the pool."
    warn "  dnsmasq could hand this address to another client. Continuing anyway."
fi

# ── Create / update the DNS host override (idempotent) ──────────────

info "  Creating DNS host override..."
dns-manager --no-ssl-verify add "${VMNAME}" "${DOMAIN}" "${DNS_IP}" \
    --description "${DESCRIPTION}" \
    || die "dns-manager add failed for ${VMNAME}.${DOMAIN}"

info "${GN}firewall:dns install-service completed for ${MODULE}${CL}"
