#!/usr/bin/env bash
#
# TAPPaaS NAT Service - Delete
#
# Removes all destination-NAT (port-forward) rules created for a consuming
# module. Every port-forward whose description starts with "TAPPaaS: <module>"
# is deleted via the nat-manager CLI, so cleanup works even if the module's
# natRules config changed since install.
#
# When firewallType is "NONE", prints a reminder to clean up manual config.
#
# Usage: delete-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., forgejo)
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
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=nat-common.sh disable=SC1091
. "${SCRIPT_DIR}/nat-common.sh"

info "network:nat delete-service for module: ${BL}${MODULE}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "Remember to remove any port-forward rules for module '${MODULE}' from your firewall."
    info "${GN}network:nat delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

# ── OPNsense: validate nat-manager ──────────────────────────────────

if ! command -v nat-manager &>/dev/null; then
    die "nat-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Remove all port-forwards for this module ────────────────────────

info "  Removing ${MODULE} port-forwards..."
REMOVED=$(nat_purge_module_rules "${MODULE}")
info "  Removed ${BL}${REMOVED}${CL} rule(s)"

info "${GN}network:nat delete-service completed for ${MODULE}${CL}"
