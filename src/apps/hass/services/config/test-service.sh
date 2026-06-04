#!/usr/bin/env bash
#
# TAPPaaS hass Config Service - Test
#
# Verifies that the hass:config service has been applied correctly:
#   1. LLAT exists in /etc/secrets/hass.env
#   2. http: block present in configuration.yaml (trusted_proxies)
#   3. external_url matches derived proxy domain
#   4. HA responds 200 with X-Forwarded-* headers (proxy chain works)
#
# Usage: test-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

check_json "/home/tappaas/config/${MODULE}.json" || exit 2

readonly CONFIG_DIR="/home/tappaas/config"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly ZONES_FILE="/home/tappaas/TAPPaaS/src/foundation/firewall/zones.json"
readonly HA_DATA_DIR="/mnt/data/supervisor/homeassistant"
readonly HA_CONFIG_YAML="${HA_DATA_DIR}/configuration.yaml"

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv_home')"
TAPPAAS_DOMAIN="$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' "${VMNAME}.${TAPPAAS_DOMAIN}")"
NODE_FQDN="${NODE}.mgmt.internal"

MGMT_CIDR="$(jq -r '.mgmt.ip // "10.0.0.0/24"' "${ZONES_FILE}")"
_cidr_gw() { echo "$1" | sed 's|/.*||' | awk -F. '{print $1"."$2"."$3".1"}'; }
HA_ZONE_GW="$(_cidr_gw "$(jq -r --arg z "${ZONE0}" '.[$z].ip // "10.2.10.0/24"' "${ZONES_FILE}")")"

HA_IP="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'hostname -I | cut -d\" \" -f1'" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data','').strip())" 2>/dev/null || echo "")"

PASS=0; FAIL=0
pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS+1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL+1)); }

info "  hass:config tests for ${BL}${MODULE}${CL}"

# Check 1: LLAT in secrets
if ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "grep -q HA_TOKEN /etc/secrets/hass.env" 2>/dev/null; then
    pass "HA_TOKEN present in /etc/secrets/hass.env"
else
    fail "HA_TOKEN missing from /etc/secrets/hass.env"
fi

# Check 2: trusted_proxies in configuration.yaml
if ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'grep -q use_x_forwarded_for ${HA_CONFIG_YAML}'" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('exitcode',1)==0 else 1)" 2>/dev/null; then
    pass "http.use_x_forwarded_for configured in configuration.yaml"
else
    fail "http block missing from configuration.yaml"
fi

# Check 3: external_url set
STORED_URL=$(ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- python3 -c \"import json; d=json.load(open('${HA_DATA_DIR}/.storage/core.config')); print(d['data'].get('external_url',''))\"" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data','').strip())" 2>/dev/null || echo "")
EXPECTED_URL="https://${PROXY_DOMAIN}"
if [[ "${STORED_URL}" == "${EXPECTED_URL}" ]]; then
    pass "external_url = ${EXPECTED_URL}"
else
    fail "external_url mismatch: got '${STORED_URL}', expected '${EXPECTED_URL}'"
fi

# Check 4: proxy chain responds 200
if [[ -n "${HA_IP}" ]]; then
    HTTP_CODE=$(curl -sf --max-time 10 \
        -H "Host: ${PROXY_DOMAIN}" \
        -H "X-Forwarded-For: 10.3.10.1" \
        -H "X-Forwarded-Proto: https" \
        -o /dev/null -w "%{http_code}" \
        "http://${HA_IP}:8123" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
        pass "HA responds ${HTTP_CODE} with proxy headers (trusted_proxies OK)"
    else
        fail "HA returned ${HTTP_CODE} with proxy headers (expected 200/302)"
    fi
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ ${FAIL} -eq 0 ]] || exit 1
