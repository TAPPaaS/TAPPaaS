#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Delete
#
# Removes discovery config owned by a module:
#   - discoveryUdpRelay: deletes relay entries with prefix "tappaas_<module>_"
#   - discoveryMdns: mdns-manager apply --without <module>: the repeater keeps the
#     zones that zones.json or another module still names.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi

debug "network:discovery delete-service for module: ${BL}${MODULE}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
[[ -f "${FIREWALL_JSON}" ]] && FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — please manually remove any discovery configuration for ${MODULE}."
    debug "${GN}network:discovery delete-service completed for ${MODULE} (manual cleanup required)${CL}"
    exit 0
fi

# ── OPNsense API credentials ─────────────────────────────────────────

CREDS_FILE="${HOME}/.opnsense-credentials.txt"
[[ -f "${CREDS_FILE}" ]] || die "OPNsense credentials not found: ${CREDS_FILE}"
KEY=$(grep '^key=' "${CREDS_FILE}" | cut -d= -f2-)
SECRET=$(grep '^secret=' "${CREDS_FILE}" | cut -d= -f2-)
[[ -z "${KEY}" || -z "${SECRET}" ]] && die "Failed to parse OPNsense credentials"

FW_HOST="${OPNSENSE_HOST:-10.0.0.1}"
API="https://${FW_HOST}:8443/api"
CURL=(-sk -u "${KEY}:${SECRET}")

# ── Remove UDP relay entries owned by this module ────────────────────

MODULE_SAFE="${MODULE//-/_}"
DESC_PREFIX="tappaas_${MODULE_SAFE}_"

RELAY_ROWS=$(curl "${CURL[@]}" "${API}/udpbroadcastrelay/settings/searchRelay" \
    | jq -c --arg prefix "${DESC_PREFIX}" \
        '.rows[] | select(.description | startswith($prefix))')

DELETED=0
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    uuid=$(echo "${row}" | jq -r '.uuid')
    desc=$(echo "${row}" | jq -r '.description')
    debug "  Removing UDP relay: ${desc} (${uuid})"
    curl "${CURL[@]}" -X POST \
        "${API}/udpbroadcastrelay/settings/delRelay/${uuid}" >/dev/null
    (( DELETED++ )) || true
done <<< "${RELAY_ROWS}"

if (( DELETED > 0 )); then
    curl "${CURL[@]}" -X POST "${API}/udpbroadcastrelay/service/reload" >/dev/null
    debug "  Removed ${DELETED} UDP relay entry/entries; service reloaded."
else
    debug "  No UDP relay entries found for module '${MODULE}'."
fi

# ── mDNS repeater ────────────────────────────────────────────────────
# mdns-manager converges the whole repeater without this module's declaration:
# a zone another module or zones.json still names stays in (#257).

if [[ -f "${MODULE_JSON}" ]] && [[ "$(read_module_config "${MODULE}" | jq -r '.discoveryMdns // "false"')" != "false" ]]; then
    MDNS_OUT=$(/home/tappaas/bin/mdns-manager --no-ssl-verify apply --config-dir "${CONFIG_DIR}" \
        --without "${MODULE}" 2>&1) || die "mdns-manager apply failed: ${MDNS_OUT}"
    while IFS= read -r _l; do debug "  ${_l}"; done <<< "${MDNS_OUT}"
else
    debug "  No discoveryMdns declared — skipping mDNS cleanup."
fi

debug "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
