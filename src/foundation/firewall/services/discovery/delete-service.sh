#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Delete
#
# Removes UDP broadcast relay entries owned by a module (identified by
# description prefix "tappaas:<module>:"). Reloads the relay service if
# any entries were removed.
#
# mDNS repeater interfaces are NOT automatically cleaned up: they are shared
# across all modules and removing one module's zone0 could break others.
# If cleanup is needed, update os-mdns-repeater manually via OPNsense UI.
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
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:discovery delete-service for module: ${BL}${MODULE}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
[[ -f "${FIREWALL_JSON}" ]] && FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — please manually remove any discovery relay configuration for ${MODULE}."
    info "${GN}firewall:discovery delete-service completed for ${MODULE} (manual cleanup required)${CL}"
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

# Description format uses underscores (OPNsense DescriptionField rejects hyphens)
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
    info "  Removing UDP relay: ${desc} (${uuid})"
    curl "${CURL[@]}" -X POST \
        "${API}/udpbroadcastrelay/settings/delRelay/${uuid}" >/dev/null
    (( DELETED++ )) || true
done <<< "${RELAY_ROWS}"

if (( DELETED > 0 )); then
    curl "${CURL[@]}" -X POST "${API}/udpbroadcastrelay/service/reload" >/dev/null
    info "  Removed ${DELETED} UDP relay entry/entries; service reloaded."
else
    info "  No UDP relay entries found for module '${MODULE}'."
fi

# ── mDNS: warn if module used mDNS ──────────────────────────────────

HAS_MDNS="false"
[[ -f "${MODULE_JSON}" ]] && HAS_MDNS=$(jq -r '.discoveryMdns // false' "${MODULE_JSON}")
if [[ "${HAS_MDNS}" == "true" ]]; then
    ZONE0=$(jq -r '.zone0 // "unknown"' "${MODULE_JSON}")
    warn "  mDNS repeater interfaces are shared and NOT automatically removed."
    warn "  If '${MODULE}' was the last module using zone '${ZONE0}' for mDNS,"
    warn "  remove it manually: OPNsense → Services → mDNS Repeater."
fi

info "${GN}firewall:discovery delete-service completed for ${MODULE}${CL}"
