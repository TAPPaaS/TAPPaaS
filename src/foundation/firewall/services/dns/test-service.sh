#!/usr/bin/env bash
#
# TAPPaaS DNS Service - Test
#
# Verifies the module's DNS host override is present in OPNsense and (when the
# module declares an ip) resolves to the expected IP. Returns non-zero on drift.
#
# Usage: test-service.sh <module-name> [--deep]
#

set -euo pipefail

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: test-service.sh <module-name> [--deep]"
    exit 1
fi

# CONFIG_DIR provided by common-install-routines.sh.
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:dns test-service for module: ${BL}${MODULE}${CL}"

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "firewallType=NONE — no automated DNS entry to verify."
    info "${GN}firewall:dns test-service completed for ${MODULE} (skipped)${CL}"
    exit 0
fi

# ── Resolve expected host and IP ────────────────────────────────────

VMNAME=$(get_config_value 'vmname' '')
[[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"
ZONE=$(get_config_value 'zone0' '')
[[ -z "${ZONE}" ]] && die "zone0 not set for ${MODULE}"
DOMAIN="${ZONE}.internal"
DNS_IP=$(get_config_value 'ip' '')
FQDN="${VMNAME}.${DOMAIN}"

# ── OPNsense: validate dns-manager ──────────────────────────────────

if ! command -v dns-manager &>/dev/null; then
    die "dns-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

LIST_OUTPUT=$(dns-manager --no-ssl-verify list 2>&1) || die "dns-manager list failed"

if ! grep -qiE "(^|[[:space:]])${FQDN}([[:space:]]|\$)" <<< "${LIST_OUTPUT}"; then
    error "${RD}DNS host override ${FQDN} not found in OPNsense${CL}"
    exit 1
fi

# When an ip is declared, confirm the entry resolves to it.
if [[ -n "${DNS_IP}" && "${DNS_IP}" != "null" ]]; then
    if ! grep -E "${FQDN}" <<< "${LIST_OUTPUT}" | grep -qF "${DNS_IP}"; then
        error "${RD}DNS host ${FQDN} exists but does not resolve to expected ${DNS_IP}${CL}"
        exit 1
    fi
fi

info "${GN}firewall:dns test-service passed for ${MODULE} (${FQDN})${CL}"
exit 0
