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

# nat_quiet <command...> — run a nat-manager call whose stdout is its own
# narration ("Port-forward set: …", "Port-forward changes applied"): [Debug]
# when it succeeds, printed when it does not. The service says what it is doing
# itself, one line per rule.
nat_quiet() {
    local out rc=0 line
    out="$("$@" 2>&1)" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        while IFS= read -r line; do [[ -n "${line}" ]] && debug "  ${line}"; done <<< "${out}"
    else
        printf '%s\n' "${out}" >&2
    fi
    return ${rc}
}

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
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

debug "network:nat update-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

RULE_COUNT=$(nat_rule_count)
debug "  Desired rules: ${BL}${RULE_COUNT}${CL}"

# ── Resolve the internal target (shared by all rules) ───────────────

TARGET=""
if [[ "${RULE_COUNT}" -gt 0 ]]; then
    if ! TARGET=$(nat_resolve_target "${MODULE}"); then
        die "Cannot resolve internal target for ${MODULE} — set an 'ip' field or ensure DNS for <vmname>.<zone0>.internal exists."
    fi
    debug "  Target: ${BL}${TARGET}${CL}"
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
    debug "${GN}network:nat update-service completed for ${MODULE} (manual config required)${CL}"
    exit 0
fi

# ── OPNsense: validate nat-manager ──────────────────────────────────

if ! command -v nat-manager &>/dev/null; then
    die "nat-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Sweep existing rules for this module ────────────────────────────

debug "  Removing existing ${MODULE} port-forwards..."
REMOVED=$(nat_purge_module_rules "${MODULE}")
debug "  Removed ${BL}${REMOVED}${CL} existing rule(s)"

# ── Recreate from current config ────────────────────────────────────

if [[ "${RULE_COUNT}" -eq 0 ]]; then
    debug "${GN}network:nat update-service completed for ${MODULE} (no rules configured)${CL}"
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

    debug "  Creating port-forward: ${proto} WAN:${BL}${ext}${CL} -> ${BL}${TARGET}:${intp}${CL}"
    nat_quiet nat-manager add-rule --no-ssl-verify --no-apply \
        --description "${desc}" \
        --external-port "${ext}" \
        --target "${TARGET}" \
        --internal-port "${intp}" \
        --protocol "${proto}" \
        || die "Failed to create port-forward (${desc})"
done < <(nat_rules_json)

debug "  Applying NAT configuration..."
nat_quiet nat-manager apply --no-ssl-verify || die "Failed to apply NAT configuration"

debug "${GN}network:nat update-service completed for ${MODULE}${CL}"
