#!/usr/bin/env bash
#
# TAPPaaS Rules Service - Test
#
# Verifies that every rule the module declares is currently present in OPNsense
# with the expected description prefix. Returns non-zero on drift.
#
# With --deep, the rules-manager additionally runs connectivity probes
# (currently a stub — see rules_manager.py:verify_rules).
#
# Usage: test-service.sh <module-name> [--deep]
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
DEEP_FLAG=""
if [[ "${2:-}" == "--deep" ]]; then
    DEEP_FLAG="--deep"
fi

if [[ -z "${MODULE}" ]]; then
    error "Usage: test-service.sh <module-name> [--deep]"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:rules test-service for module: ${BL}${MODULE}${CL}"

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "firewallType=NONE — no automated rules to verify."
    info "${GN}firewall:rules test-service completed for ${MODULE} (skipped)${CL}"
    exit 0
fi

if ! command -v rules-manager &>/dev/null; then
    die "rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

if rules-manager verify-rules "${MODULE}" ${DEEP_FLAG} \
        --firewall-type "${FIREWALL_TYPE}" \
        --no-ssl-verify; then
    info "${GN}firewall:rules test-service passed for ${MODULE}${CL}"
    exit 0
else
    error "${RD}firewall:rules test-service detected drift for ${MODULE}${CL}"
    exit 1
fi
