#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Install
#
# Configures cross-VLAN discovery on OPNsense for a consuming module:
#   - discoveryMdns: true  → adds zone0 + home + srv_home to os-mdns-repeater
#   - discoveryUdpRelay[]  → adds per-port relay instances to os-udpbroadcastrelay
#
# Both operations are idempotent: mDNS uses GET→union→SET, UDP relay checks
# description "tappaas:<module>:<port>" before adding.
#
# When firewallType is "NONE", prints manual instructions and exits 0.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:discovery install-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# ── Read discovery config ────────────────────────────────────────────

ZONE0=$(get_config_value 'zone0' '')
UDP_RELAY_COUNT=$(read_module_config "${MODULE}" | jq -r '(.discoveryUdpRelay // []) | length')

# discoveryMdns accepts an array of consumer zone names (e.g. ["home","srv_home"]).
# Legacy boolean true is still accepted but deprecated — emit a warning and treat as
# empty consumer list (zone0 is still added; run update-service to migrate).
MDNS_RAW=$(read_module_config "${MODULE}" | jq -r '.discoveryMdns // "false"')
MDNS_ZONES_COUNT=0
if [[ "${MDNS_RAW}" == "true" ]]; then
    warn "  discoveryMdns: true is deprecated. Use an array of consumer zones, e.g. [\"home\",\"srv_home\"]."
    MDNS_ZONES_COUNT=0
elif [[ "${MDNS_RAW}" != "false" ]]; then
    MDNS_ZONES_COUNT=$(read_module_config "${MODULE}" | jq -r '.discoveryMdns | length')
fi
HAS_MDNS=$([[ "${MDNS_RAW}" != "false" ]] && echo "true" || echo "false")

if [[ "${HAS_MDNS}" == "false" && "${UDP_RELAY_COUNT}" == "0" ]]; then
    info "  No discoveryMdns or discoveryUdpRelay declared — nothing to apply."
    info "${GN}firewall:discovery install-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
[[ -f "${FIREWALL_JSON}" ]] && FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — manual configuration required:"
    if [[ "${HAS_MDNS}" == "true" ]]; then
        warn "  Install os-mdns-repeater; add interfaces for zones: ${ZONE0}, home, srv_home"
    fi
    if (( UDP_RELAY_COUNT > 0 )); then
        read_module_config "${MODULE}" | jq -r '.discoveryUdpRelay[]? |
            "  Install os-udpbroadcastrelay; UDP relay port \(.port) for zones: \(.zones | join(", "))"'
    fi
    info "${GN}firewall:discovery install-service completed for ${MODULE} (manual config required)${CL}"
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

# ── Fetch mDNS interface map ─────────────────────────────────────────
# Used for zone-name → OPNsense interface-id resolution (e.g. iot_cloud → opt21).
# mDNS GET returns all available interfaces; we parse the value strings.
# If the endpoint returns an error, os-mdns-repeater is not installed.

MDNS_RESP=$(curl "${CURL[@]}" "${API}/mdnsrepeater/settings/get")
if ! echo "${MDNS_RESP}" | jq -e '.mdnsrepeater.interfaces' >/dev/null 2>&1; then
    die "os-mdns-repeater plugin not available (API returned: ${MDNS_RESP}). Install it via OPNsense > System > Firmware > Plugins."
fi
IFACE_JSON=$(echo "${MDNS_RESP}" | jq '.mdnsrepeater.interfaces')

resolve_iface() {
    # OPNsense interface labels and zone names are both in underscore form
    # after the #237 SSOT alignment — no transformation needed.
    local zone="$1"
    echo "${IFACE_JSON}" | jq -r --arg z "${zone}" \
        'to_entries[]
         | select(.value.value | ascii_downcase | startswith(($z | ascii_downcase)))
         | .key' \
        | head -1
}

# ── mDNS repeater ────────────────────────────────────────────────────

if [[ "${HAS_MDNS}" == "true" ]]; then
    [[ -z "${ZONE0}" ]] && die "discoveryMdns set but zone0 not set in ${MODULE_JSON}"
    info "  Configuring mDNS repeater (zone0=${ZONE0}, consumer zones: ${MDNS_ZONES_COUNT})..."

    ZONE0_IFACE=$(resolve_iface "${ZONE0}")
    [[ -z "${ZONE0_IFACE}" ]] && die "Cannot resolve OPNsense interface for zone: ${ZONE0}"

    # Resolve each consumer zone declared in discoveryMdns[]
    CONSUMER_IFACES=""
    if (( MDNS_ZONES_COUNT > 0 )); then
        while IFS= read -r zone; do
            iface=$(resolve_iface "${zone}")
            [[ -n "${iface}" ]] && CONSUMER_IFACES="${CONSUMER_IFACES} ${iface}"
        done < <(read_module_config "${MODULE}" | jq -r '.discoveryMdns[]')
    fi

    # Union current selected interfaces with zone0 + consumer zones (deduplicate)
    CURRENT=$(echo "${MDNS_RESP}" | jq -r \
        '.mdnsrepeater.interfaces | to_entries[] | select(.value.selected == 1) | .key')
    ALL_IFACES=$(printf '%s\n' ${CURRENT} "${ZONE0_IFACE}" ${CONSUMER_IFACES} \
        | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')

    info "  mDNS interfaces set: ${BL}${ALL_IFACES}${CL}"

    SAVE_RESP=$(curl "${CURL[@]}" -X POST -H "Content-Type: application/json" \
        -d "{\"mdnsrepeater\":{\"enabled\":\"1\",\"interfaces\":\"${ALL_IFACES}\"}}" \
        "${API}/mdnsrepeater/settings/set")
    echo "${SAVE_RESP}" | jq -e '.result == "saved"' >/dev/null \
        || die "mDNS settings/set failed: ${SAVE_RESP}"

    # reconfigure rebuilds the configd config file from config.xml and starts/restarts the daemon.
    # service/restart alone does not rebuild the config and leaves the daemon stopped.
    curl "${CURL[@]}" -X POST "${API}/mdnsrepeater/service/reconfigure" >/dev/null
    info "  mDNS repeater reconfigured and started."
fi

# ── UDP broadcast relay ──────────────────────────────────────────────

if (( UDP_RELAY_COUNT > 0 )); then
    info "  Configuring UDP broadcast relay (${UDP_RELAY_COUNT} entries)..."

    RELAY_SEARCH=$(curl "${CURL[@]}" "${API}/udpbroadcastrelay/settings/searchRelay")
    EXISTING_DESCS=$(echo "${RELAY_SEARCH}" | jq -r '.rows[].description // ""')

    # OPNsense DescriptionField rejects hyphens; use underscores throughout.
    # InstanceID must be unique integer 1-63; find the next available one.
    MODULE_SAFE="${MODULE//-/_}"

    next_instance_id() {
        local used_ids
        used_ids=$(echo "${RELAY_SEARCH}" | jq -r '[.rows[].InstanceID | tonumber] | sort[]' 2>/dev/null || echo "")
        for i in $(seq 1 63); do
            if ! echo "${used_ids}" | grep -qx "${i}"; then
                echo "${i}"
                return
            fi
        done
        die "All 63 InstanceID slots are in use for os-udpbroadcastrelay"
    }

    RELAY_ADDED=0
    while IFS= read -r entry; do
        PORT=$(echo "${entry}" | jq -r '.port')
        # Description: underscores only (OPNsense DescriptionField rejects hyphens)
        DESC="tappaas_${MODULE_SAFE}_${PORT}"

        if echo "${EXISTING_DESCS}" | grep -qF "${DESC}"; then
            info "  UDP relay port ${PORT} (${DESC}) already configured — skipping."
            continue
        fi

        # Resolve each zone to its OPNsense interface identifier
        ZONE_IFACES=""
        while IFS= read -r zone; do
            iface=$(resolve_iface "${zone}")
            if [[ -z "${iface}" ]]; then
                warn "  Cannot resolve interface for zone '${zone}' — skipping."
                continue
            fi
            ZONE_IFACES="${ZONE_IFACES},${iface}"
        done < <(echo "${entry}" | jq -r '.zones[]')
        ZONE_IFACES="${ZONE_IFACES#,}"

        [[ -z "${ZONE_IFACES}" ]] && die "No valid interfaces resolved for UDP relay port ${PORT}"

        INSTANCE_ID=$(next_instance_id)
        info "  Adding UDP relay: port=${PORT} ifaces=${ZONE_IFACES} id=${INSTANCE_ID} desc=${DESC}"

        ADD_RESP=$(curl "${CURL[@]}" -X POST -H "Content-Type: application/json" \
            -d "{\"udpbroadcastrelay\":{\"enabled\":\"1\",\"listenport\":\"${PORT}\",\"interfaces\":\"${ZONE_IFACES}\",\"InstanceID\":\"${INSTANCE_ID}\",\"description\":\"${DESC}\"}}" \
            "${API}/udpbroadcastrelay/settings/addRelay")
        echo "${ADD_RESP}" | jq -e '.result == "OK"' >/dev/null \
            || die "UDP relay addRelay failed: ${ADD_RESP}"

        # Update RELAY_SEARCH to reflect the new entry for next_instance_id
        RELAY_SEARCH=$(curl "${CURL[@]}" "${API}/udpbroadcastrelay/settings/searchRelay")
        (( RELAY_ADDED++ )) || true
    done < <(read_module_config "${MODULE}" | jq -c '.discoveryUdpRelay[]')

    if (( RELAY_ADDED > 0 )); then
        info "  UDP broadcast relay reloaded (${RELAY_ADDED} new entries added)."
    fi
fi

info "${GN}firewall:discovery install-service completed for ${MODULE}${CL}"
