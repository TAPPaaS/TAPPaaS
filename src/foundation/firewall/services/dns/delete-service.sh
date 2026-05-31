#!/usr/bin/env bash
#
# TAPPaaS DNS Service - Delete
#
# Removes the OPNsense DNS host override for a consuming module via the
# dns-manager CLI. Tolerant of a missing entry or missing module config.
#
# When firewallType is "NONE", prints a reminder to clean up manual config.
#
# Usage: delete-service.sh <module-name>
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
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:dns delete-service for module: ${BL}${MODULE}${CL}"

# ── Resolve hostname (vmname) and domain (<zone0>.internal) ─────────
# Tolerant: if the module config is gone we can still attempt cleanup by name.

VMNAME="${MODULE}"
DOMAIN=""
if [[ -f "${MODULE_JSON}" ]]; then
    VMNAME=$(get_config_value 'vmname' '')
    [[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"
    ZONE=$(get_config_value 'zone0' '')
    [[ -n "${ZONE}" ]] && DOMAIN="${ZONE}.internal"
else
    warn "Module config not found: ${MODULE_JSON} — limited cleanup possible"
fi

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    if [[ -n "${DOMAIN}" ]]; then
        warn "Remember to remove the DNS host override ${BL}${VMNAME}.${DOMAIN}${CL} from your DNS server."
    else
        warn "Remember to remove any DNS host override for module '${MODULE}' from your DNS server."
    fi
    info "${GN}firewall:dns delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

if [[ -z "${DOMAIN}" ]]; then
    warn "Cannot determine DNS domain (zone0 unavailable) — skipping automated cleanup"
    info "${GN}firewall:dns delete-service completed for ${MODULE} (nothing removed)${CL}"
    exit 0
fi

# ── OPNsense: validate dns-manager ──────────────────────────────────

if ! command -v dns-manager &>/dev/null; then
    die "dns-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Delete the DNS host override ────────────────────────────────────

info "  Deleting DNS host override ${BL}${VMNAME}.${DOMAIN}${CL}..."
dns-manager --no-ssl-verify delete "${VMNAME}" "${DOMAIN}" \
    || warn "Could not delete DNS host ${VMNAME}.${DOMAIN} (may not exist)"

info "${GN}firewall:dns delete-service completed for ${MODULE}${CL}"
