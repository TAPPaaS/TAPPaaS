#!/usr/bin/env bash
#
# TAPPaaS Rules Service - Install
#
# Compiles `ports`, `ingress`, `egress`, and `aliases` from a consuming module's
# JSON declaration and applies the resulting firewall rules and aliases to
# OPNsense via the rules-manager CLI.
#
# When firewallType is "NONE" (no OPNsense deployed), rules-manager prints the
# manual configuration the deployer needs to apply on their own firewall and
# exits successfully — no OPNsense connection is attempted.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
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
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:rules install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ── Determine firewallType (system-wide, from firewall.json) ────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

# ── Short-circuit when the module has no firewall:rules content ─────

INGRESS_COUNT=$(jq -r '(.ingress // []) | length' "${MODULE_JSON}")
EGRESS_COUNT=$(jq -r '(.egress // []) | length' "${MODULE_JSON}")
ALIAS_COUNT=$(jq -r '(.aliases // {}) | length' "${MODULE_JSON}")

if (( INGRESS_COUNT == 0 && EGRESS_COUNT == 0 && ALIAS_COUNT == 0 )); then
    info "  No ports/ingress/egress/aliases declared — nothing to apply."
    info "${GN}firewall:rules install-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

# ── Validate rules-manager availability ─────────────────────────────

if ! command -v rules-manager &>/dev/null; then
    die "rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Apply ────────────────────────────────────────────────────────────

info "  ingress=${INGRESS_COUNT} egress=${EGRESS_COUNT} aliases=${ALIAS_COUNT} firewallType=${FIREWALL_TYPE}"

rules-manager add-rules "${MODULE}" \
    --firewall-type "${FIREWALL_TYPE}" \
    --no-ssl-verify \
    || die "rules-manager add-rules failed for ${MODULE}"

info "${GN}firewall:rules install-service completed for ${MODULE}${CL}"
