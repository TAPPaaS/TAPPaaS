#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Delete
#
# Removes discovery config owned by a module:
#   - discoveryUdpRelay: deletes relay entries with prefix "tappaas_<module>_"
#   - discoveryMdns: removes zone0 + consumer zones from os-mdns-repeater,
#     but only if no other installed module still needs them (shared-interface safety).
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

info "network:discovery delete-service for module: ${BL}${MODULE}${CL}"

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
[[ -f "${FIREWALL_JSON}" ]] && FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — please manually remove any discovery configuration for ${MODULE}."
    info "${GN}network:discovery delete-service completed for ${MODULE} (manual cleanup required)${CL}"
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

# ── Remove mDNS repeater interfaces no longer needed ────────────────
# Only removes interfaces that no other installed module still needs.

if [[ ! -f "${MODULE_JSON}" ]]; then
    info "  Module config not found — skipping mDNS cleanup."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi

MDNS_RAW=$(read_module_config "${MODULE}" | jq -r '.discoveryMdns // "false"')

if [[ "${MDNS_RAW}" == "false" ]]; then
    info "  No discoveryMdns declared — skipping mDNS cleanup."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi

info "  Checking mDNS repeater cleanup..."

# Collect zones contributed by this module (zone0 + consumer zones)
THIS_ZONES=()
ZONE0=$(get_config_value 'zone0' '')
[[ -n "${ZONE0}" ]] && THIS_ZONES+=("${ZONE0}")
if [[ "${MDNS_RAW}" != "true" ]]; then
    while IFS= read -r zone; do
        THIS_ZONES+=("${zone}")
    done < <(read_module_config "${MODULE}" | jq -r '.discoveryMdns[]')
fi

if [[ "${#THIS_ZONES[@]}" -eq 0 ]]; then
    info "  No mDNS zones to clean up."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi

# Collect zones still needed by other installed modules
OTHER_ZONES=()
for config_file in "${CONFIG_DIR}"/*.json; do
    other_module=$(basename "${config_file}" .json)
    [[ "${other_module}" == "${MODULE}" ]] && continue

    other_mdns=$(jq -r '.discoveryMdns // "false"' "${config_file}" 2>/dev/null) || continue
    [[ "${other_mdns}" == "false" ]] && continue

    other_zone0=$(jq -r '.zone0 // empty' "${config_file}")
    [[ -n "${other_zone0}" ]] && OTHER_ZONES+=("${other_zone0}")

    if [[ "${other_mdns}" != "true" ]]; then
        while IFS= read -r zone; do
            OTHER_ZONES+=("${zone}")
        done < <(jq -r '.discoveryMdns[]' "${config_file}")
    fi
done

# Compute which of this module's zones are safe to remove
SAFE_TO_REMOVE=()
for zone in "${THIS_ZONES[@]}"; do
    needed=false
    for other_zone in "${OTHER_ZONES[@]}"; do
        [[ "${zone}" == "${other_zone}" ]] && { needed=true; break; }
    done
    if [[ "${needed}" == "false" ]]; then
        SAFE_TO_REMOVE+=("${zone}")
    else
        info "  Zone '${zone}' still needed by another module — keeping."
    fi
done

if [[ "${#SAFE_TO_REMOVE[@]}" -eq 0 ]]; then
    info "  All mDNS zones still needed by other modules — nothing removed."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi

# Resolve zone names → OPNsense interface identifiers
MDNS_RESP=$(curl "${CURL[@]}" "${API}/mdnsrepeater/settings/get")
if ! echo "${MDNS_RESP}" | jq -e '.mdnsrepeater.interfaces' >/dev/null 2>&1; then
    warn "  os-mdns-repeater not available — skipping mDNS cleanup."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi
IFACE_JSON=$(echo "${MDNS_RESP}" | jq '.mdnsrepeater.interfaces')

resolve_iface() {
    # Zone names and OPNsense interface labels are both underscore (#237).
    local zone="$1"
    echo "${IFACE_JSON}" | jq -r --arg z "${zone}" \
        'to_entries[]
         | select(.value.value | ascii_downcase | startswith(($z | ascii_downcase)))
         | .key' \
        | head -1
}

REMOVE_IFACES=()
for zone in "${SAFE_TO_REMOVE[@]}"; do
    iface=$(resolve_iface "${zone}")
    if [[ -z "${iface}" ]]; then
        warn "  Cannot resolve interface for zone '${zone}' — skipping."
    else
        REMOVE_IFACES+=("${iface}")
        info "  Will remove mDNS interface: ${zone} → ${iface}"
    fi
done

if [[ "${#REMOVE_IFACES[@]}" -eq 0 ]]; then
    info "  No mDNS interfaces resolved for removal."
    info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
    exit 0
fi

# Build new interface set: current selected minus the ones to remove
CURRENT=$(echo "${MDNS_RESP}" | jq -r \
    '.mdnsrepeater.interfaces | to_entries[] | select(.value.selected == 1) | .key')

NEW_IFACES=""
while IFS= read -r iface; do
    [[ -z "${iface}" ]] && continue
    skip=false
    for rm_iface in "${REMOVE_IFACES[@]}"; do
        [[ "${iface}" == "${rm_iface}" ]] && { skip=true; break; }
    done
    [[ "${skip}" == "false" ]] && NEW_IFACES="${NEW_IFACES},${iface}"
done <<< "${CURRENT}"
NEW_IFACES="${NEW_IFACES#,}"

SAVE_RESP=$(curl "${CURL[@]}" -X POST -H "Content-Type: application/json" \
    -d "{\"mdnsrepeater\":{\"enabled\":\"1\",\"interfaces\":\"${NEW_IFACES}\"}}" \
    "${API}/mdnsrepeater/settings/set")
echo "${SAVE_RESP}" | jq -e '.result == "saved"' >/dev/null \
    || die "mDNS settings/set failed: ${SAVE_RESP}"

curl "${CURL[@]}" -X POST "${API}/mdnsrepeater/service/reconfigure" >/dev/null
info "  mDNS repeater updated: removed ${#REMOVE_IFACES[@]} interface(s), reconfigured."

info "${GN}network:discovery delete-service completed for ${MODULE}${CL}"
