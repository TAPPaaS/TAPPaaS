#!/usr/bin/env bash
#
# TAPPaaS NAT Service - Install
#
# Configures destination-NAT (port-forward) rules on OPNsense for a consuming
# module, exposing internal service ports on the firewall's WAN interface.
# Each rule is created as an rdr-pass rule via the nat-manager CLI: OPNsense
# translates the destination AND passes the traffic in one atomic rule, so no
# separate WAN filter rule is required.
#
# Driving example (issue #285): forgejo exposing SSH as mydomain.org:2022 -> :22.
#
# When firewallType is "NONE" (no OPNsense deployed), this script prints the
# port-forward rules the deployer must apply manually, then exits successfully.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., forgejo)
#
# The script reads the module JSON from /home/tappaas/config/<module>.json,
# resolves the internal target (the module's `ip`, or <vmname>.<zone0>.internal),
# then for each entry in `natRules` creates a port-forward via nat-manager.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=nat-common.sh disable=SC1091
. "${SCRIPT_DIR}/nat-common.sh"

info "firewall:nat install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

RULE_COUNT=$(nat_rule_count)
if [[ "${RULE_COUNT}" -eq 0 ]]; then
    warn "Module '${MODULE}' depends on firewall:nat but defines no natRules — nothing to do."
    info "${GN}firewall:nat install-service completed for ${MODULE} (no rules)${CL}"
    exit 0
fi

# ── Resolve the internal target (shared by all rules) ───────────────

if ! TARGET=$(nat_resolve_target "${MODULE}"); then
    die "Cannot resolve internal target for ${MODULE} — set an 'ip' field or ensure DNS for <vmname>.<zone0>.internal exists."
fi
info "  Target: ${BL}${TARGET}${CL} (${RULE_COUNT} rule(s))"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "The module '${MODULE}' requires the following port-forward rules:"
    while IFS= read -r rule; do
        [[ -z "${rule}" ]] && continue
        ext=$(nat_rule_external_port "${rule}")
        intp=$(nat_rule_internal_port "${rule}")
        proto=$(nat_rule_protocol "${rule}")
        warn "  ${BOLD}${proto}${CL} WAN:${BL}${ext}${CL} -> ${BL}${TARGET}:${intp}${CL}"
    done < <(nat_rules_json)
    warn "Create these port-forwards on your firewall, then continue."
    info "${GN}firewall:nat install-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate nat-manager ──────────────────────────────────

if ! command -v nat-manager &>/dev/null; then
    die "nat-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Create each port-forward (apply once at the end) ────────────────

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

# ── Apply ────────────────────────────────────────────────────────────

info "  Applying NAT configuration..."
nat-manager apply --no-ssl-verify || die "Failed to apply NAT configuration"

info "${GN}firewall:nat install-service completed for ${MODULE}${CL}"
