#!/usr/bin/env bash
#
# TAPPaaS Discovery Service - Test
#
# Verifies that every discovery entry declared in a module's JSON is present
# in OPNsense:
#   - discoveryMdns: zone0 + each consumer zone is in os-mdns-repeater
#   - discoveryUdpRelay: each port has a relay entry in os-udpbroadcastrelay
#
# Returns non-zero on drift (declared but missing in OPNsense).
#
# Usage: test-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: test-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"

info "firewall:discovery test-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# ── Read discovery config ────────────────────────────────────────────

ZONE0=$(jq -r '.zone0 // empty' "${MODULE_JSON}")
UDP_RELAY_COUNT=$(jq -r '(.discoveryUdpRelay // []) | length' "${MODULE_JSON}")

MDNS_RAW=$(jq -r '.discoveryMdns // "false"' "${MODULE_JSON}")
HAS_MDNS="false"
MDNS_ZONES_COUNT=0
if [[ "${MDNS_RAW}" == "true" ]]; then
    HAS_MDNS="true"
    MDNS_ZONES_COUNT=0
elif [[ "${MDNS_RAW}" != "false" ]]; then
    HAS_MDNS="true"
    MDNS_ZONES_COUNT=$(jq -r '.discoveryMdns | length' "${MODULE_JSON}")
fi

if [[ "${HAS_MDNS}" == "false" && "${UDP_RELAY_COUNT}" == "0" ]]; then
    info "  No discoveryMdns or discoveryUdpRelay declared — nothing to verify."
    info "${GN}firewall:discovery test-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

# ── firewallType ─────────────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
[[ -f "${FIREWALL_JSON}" ]] && FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    info "  firewallType=NONE — no automated discovery to verify."
    info "${GN}firewall:discovery test-service completed for ${MODULE} (skipped)${CL}"
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

FAILURES=0

# ── Helper: resolve zone name → OPNsense interface id ───────────────

resolve_iface() {
    local zone="$1"
    echo "${IFACE_JSON}" | jq -r --arg z "${zone}" \
        'to_entries[]
         | select(.value.value | ascii_downcase | startswith(($z | gsub("-";"_") | ascii_downcase)))
         | .key' \
        | head -1
}

# ── Test: mDNS repeater ──────────────────────────────────────────────

if [[ "${HAS_MDNS}" == "true" ]]; then
    info "  Checking mDNS repeater..."

    MDNS_RESP=$(curl "${CURL[@]}" "${API}/mdnsrepeater/settings/get")
    if ! echo "${MDNS_RESP}" | jq -e '.mdnsrepeater.interfaces' >/dev/null 2>&1; then
        error "  os-mdns-repeater plugin not available."
        (( FAILURES++ )) || true
    else
        IFACE_JSON=$(echo "${MDNS_RESP}" | jq '.mdnsrepeater.interfaces')

        # zone0 must always be present
        ZONE0_IFACE=$(resolve_iface "${ZONE0}")
        if [[ -z "${ZONE0_IFACE}" ]]; then
            error "  Cannot resolve interface for zone0=${ZONE0}"
            (( FAILURES++ )) || true
        else
            SELECTED=$(echo "${MDNS_RESP}" | jq -r \
                --arg iface "${ZONE0_IFACE}" \
                '.mdnsrepeater.interfaces[$iface].selected // 0')
            if [[ "${SELECTED}" == "1" ]]; then
                info "  mDNS zone0 (${ZONE0} → ${ZONE0_IFACE}): ${GN}present${CL}"
            else
                error "  mDNS zone0 (${ZONE0} → ${ZONE0_IFACE}): ${RD}MISSING${CL}"
                (( FAILURES++ )) || true
            fi
        fi

        # each declared consumer zone must be present
        if (( MDNS_ZONES_COUNT > 0 )); then
            while IFS= read -r zone; do
                iface=$(resolve_iface "${zone}")
                if [[ -z "${iface}" ]]; then
                    error "  Cannot resolve interface for consumer zone=${zone}"
                    (( FAILURES++ )) || true
                    continue
                fi
                selected=$(echo "${MDNS_RESP}" | jq -r \
                    --arg iface "${iface}" \
                    '.mdnsrepeater.interfaces[$iface].selected // 0')
                if [[ "${selected}" == "1" ]]; then
                    info "  mDNS consumer zone (${zone} → ${iface}): ${GN}present${CL}"
                else
                    error "  mDNS consumer zone (${zone} → ${iface}): ${RD}MISSING${CL}"
                    (( FAILURES++ )) || true
                fi
            done < <(jq -r '.discoveryMdns[]' "${MODULE_JSON}")
        fi
    fi
fi

# ── Test: UDP broadcast relay ────────────────────────────────────────

if (( UDP_RELAY_COUNT > 0 )); then
    info "  Checking UDP broadcast relay..."

    MODULE_SAFE="${MODULE//-/_}"
    RELAY_SEARCH=$(curl "${CURL[@]}" "${API}/udpbroadcastrelay/settings/searchRelay")
    EXISTING_DESCS=$(echo "${RELAY_SEARCH}" | jq -r '.rows[].description // ""')

    while IFS= read -r entry; do
        PORT=$(echo "${entry}" | jq -r '.port')
        DESC="tappaas_${MODULE_SAFE}_${PORT}"
        if echo "${EXISTING_DESCS}" | grep -qF "${DESC}"; then
            info "  UDP relay port ${PORT} (${DESC}): ${GN}present${CL}"
        else
            error "  UDP relay port ${PORT} (${DESC}): ${RD}MISSING${CL}"
            (( FAILURES++ )) || true
        fi
    done < <(jq -c '.discoveryUdpRelay[]' "${MODULE_JSON}")
fi

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}firewall:discovery test-service passed for ${MODULE}${CL}"
    exit 0
else
    error "${RD}firewall:discovery test-service detected ${FAILURES} drift(s) for ${MODULE}${CL}"
    exit 1
fi
