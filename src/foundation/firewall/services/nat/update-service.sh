#!/usr/bin/env bash
#
# TAPPaaS NAT Service - Update
#
# Reconciles the destination-NAT (port-forward) rules on OPNsense for a
# consuming module to match its current natRules config. Reconciliation is a
# clean sweep: every existing "TAPPaaS: <module> ..." port-forward is removed,
# then the rules currently declared in the module JSON are recreated. This
# correctly handles added, changed, and removed rules in one pass.
#
# When firewallType is "NONE", prints the desired rules as a manual reminder.
#
# Usage: update-service.sh <module-name>
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
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=nat-common.sh disable=SC1091
. "${SCRIPT_DIR}/nat-common.sh"

info "firewall:nat update-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

RULE_COUNT=$(nat_rule_count)
info "  Desired rules: ${BL}${RULE_COUNT}${CL}"

# ── Resolve the internal target (shared by all rules) ───────────────

TARGET=""
if [[ "${RULE_COUNT}" -gt 0 ]]; then
    if ! TARGET=$(nat_resolve_target "${MODULE}"); then
        die "Cannot resolve internal target for ${MODULE} — set an 'ip' field or ensure DNS for <vmname>.<zone0>.internal exists."
    fi
    info "  Target: ${BL}${TARGET}${CL}"
fi

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "Ensure the following port-forward rules exist for module '${MODULE}':"
    while IFS= read -r rule; do
        [[ -z "${rule}" ]] && continue
        ext=$(nat_rule_external_port "${rule}")
        intp=$(nat_rule_internal_port "${rule}")
        proto=$(nat_rule_protocol "${rule}")
        warn "  ${BOLD}${proto}${CL} WAN:${BL}${ext}${CL} -> ${BL}${TARGET}:${intp}${CL}"
    done < <(nat_rules_json)
    info "${GN}firewall:nat update-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate nat-manager ──────────────────────────────────

if ! command -v nat-manager &>/dev/null; then
    die "nat-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Sweep existing rules for this module ────────────────────────────

info "  Removing existing ${MODULE} port-forwards..."
REMOVED=$(nat_purge_module_rules "${MODULE}")
info "  Removed ${BL}${REMOVED}${CL} existing rule(s)"

# ── Recreate from current config ────────────────────────────────────

if [[ "${RULE_COUNT}" -eq 0 ]]; then
    info "${GN}firewall:nat update-service completed for ${MODULE} (no rules configured)${CL}"
    exit 0
fi

while IFS= read -r rule; do
    [[ -z "${rule}" ]] && continue
    ext=$(nat_rule_external_port "${rule}")
    intp=$(nat_rule_internal_port "${rule}")
    proto=$(nat_rule_protocol "${rule}")
    desc=$(nat_rule_description "${MODULE}" "${rule}")

    if [[ -z "${ext}" || "${ext}" == "null" ]]; then
        die "natRules entry for ${MODULE} is missing 'externalPort': ${rule}"
    fi

    info "  Creating port-forward: ${proto} WAN:${BL}${ext}${CL} -> ${BL}${TARGET}:${intp}${CL}"
    nat-manager add-rule --no-ssl-verify --no-apply \
        --description "${desc}" \
        --external-port "${ext}" \
        --target "${TARGET}" \
        --internal-port "${intp}" \
        --protocol "${proto}" \
        || die "Failed to create port-forward (${desc})"
done < <(nat_rules_json)

info "  Applying NAT configuration..."
nat-manager apply --no-ssl-verify || die "Failed to apply NAT configuration"

info "${GN}firewall:nat update-service completed for ${MODULE}${CL}"
