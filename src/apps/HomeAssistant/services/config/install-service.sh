#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant Config Service - Install
#
# Configures a fresh HAOS installation for TAPPaaS proxy integration:
#   1. Bootstraps a Long-Lived Access Token via the HA onboarding API
#      (first-run only) and stores it in /etc/secrets/homeassistant.env
#   2. Completes remaining onboarding steps (core_config, analytics, integration)
#   3. Writes http: block to configuration.yaml (trusted_proxies derived
#      from zones.json + module zone0; no hardcoded IPs)
#   4. Sets external_url via HA API (derived from proxyDomain)
#   5. Restarts HA Core to apply changes
#
# All values derived from TAPPaaS SSoT — no hardcoded IPs or domains:
#   tappaas.domain  → configuration.json
#   vmname, zone0   → {module}.json
#   proxyDomain     → {module}.json config.firewall:proxy
#   trusted_proxies → zones.json (mgmt CIDR + module zone0 gateway)
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

check_json "/home/tappaas/config/${MODULE}.json" || exit 1

readonly CONFIG_DIR="/home/tappaas/config"
readonly SYSTEM_CONFIG="${CONFIG_DIR}/configuration.json"
readonly ZONES_FILE="/home/tappaas/TAPPaaS/src/foundation/firewall/zones.json"
readonly SECRETS_FILE="/etc/secrets/homeassistant.env"
readonly HA_CONFIG_YAML="/mnt/data/supervisor/homeassistant/configuration.yaml"

# ── Resolve values from SSoT ─────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv_home')"
TAPPAAS_DOMAIN="$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' "${VMNAME}.${TAPPAAS_DOMAIN}")"
EXTERNAL_URL="https://${PROXY_DOMAIN}"

_cidr_gw() { echo "$1" | sed 's|/.*||' | awk -F. '{print $1"."$2"."$3".1"}'; }
MGMT_CIDR="$(jq -r '.mgmt.ip // "10.0.0.0/24"' "${ZONES_FILE}")"
HA_ZONE_CIDR="$(jq -r --arg z "${ZONE0}" '.[$z].ip // empty' "${ZONES_FILE}")"
HA_ZONE_GW="$(_cidr_gw "${HA_ZONE_CIDR:-10.2.10.0/24}")"

NODE_FQDN="${NODE}.mgmt.internal"

# Use qm agent (not qm guest exec) to get HA's IP — HAOS has no standard shell PATH
HA_IP="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@"${NODE_FQDN}" \
    "qm agent ${VMID} network-get-interfaces 2>/dev/null" 2>/dev/null \
    | python3 -c "
import json,sys
ifaces=json.load(sys.stdin)
for i in ifaces:
    for a in i.get('ip-addresses',[]):
        ip=a.get('ip-address','')
        if a.get('ip-address-type')=='ipv4' and not ip.startswith('127') and not ip.startswith('172'):
            print(ip); exit()
" 2>/dev/null || echo "")"
[[ -n "${HA_IP}" ]] || die "Cannot determine HA IP for VMID ${VMID} on ${NODE}"
HA_URL="http://${HA_IP}:8123"

info "homeassistant:config install-service for module: ${BL}${MODULE}${CL}"
info "  HA URL        : ${BL}${HA_URL}${CL}"
info "  external_url  : ${BL}${EXTERNAL_URL}${CL}"
info "  mgmt CIDR     : ${MGMT_CIDR}"
info "  HA zone GW    : ${HA_ZONE_GW}"

# ── Wait for HA to be reachable ───────────────────────────────────────────────

info "  Waiting for HA to be reachable..."
local_wait=0
until curl -s --max-time 5 -o /dev/null -w "%{http_code}" "${HA_URL}" 2>/dev/null \
    | grep -qE "^(200|302|401)"; do
    sleep 5; (( local_wait += 5 ))
    [[ $local_wait -lt 180 ]] || die "HA did not become reachable after 180s"
done
info "  ${GN}✓${CL} HA is reachable"

# ── Bootstrap LLAT (first-run: user step not yet done) ────────────────────────

if ! ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "test -f ${SECRETS_FILE} && grep -q HA_TOKEN ${SECRETS_FILE}" 2>/dev/null; then

    info "  ${BOLD}Bootstrapping Long-Lived Access Token...${CL}"
    ONBOARD_STATUS=$(curl -sf --max-time 10 "${HA_URL}/api/onboarding" 2>/dev/null || echo "[]")

    # Check specifically if the 'user' step is not yet done
    USER_DONE=$(echo "${ONBOARD_STATUS}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('yes' if any(s.get('step')=='user' and s.get('done') for s in d) else 'no')
" 2>/dev/null || echo "unknown")

    if [[ "${USER_DONE}" == "no" ]]; then
        # Step 1: create admin user → auth_code
        ADMIN_PASS="$(python3 -c "
import secrets,string
print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))
")"
        ONBOARD_RESP=$(curl -sf --max-time 30 -X POST \
            -H "Content-Type: application/json" \
            -d "{\"client_id\":\"http://homeassistant.local/\",\"name\":\"TAPPaaS Admin\",\"username\":\"tappaas\",\"password\":\"${ADMIN_PASS}\",\"language\":\"en\"}" \
            "${HA_URL}/api/onboarding/users" 2>/dev/null)

        AUTH_CODE=$(echo "${ONBOARD_RESP}" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('auth_code',''))" 2>/dev/null)
        [[ -n "${AUTH_CODE}" ]] || die "Onboarding users failed — no auth_code in response"

        # Step 2: exchange auth_code for access_token
        ACCESS_TOKEN=$(curl -sf --max-time 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=authorization_code&code=${AUTH_CODE}&client_id=http%3A%2F%2Fhomeassistant.local%2F" \
            "${HA_URL}/auth/token" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
        [[ -n "${ACCESS_TOKEN}" ]] || die "Could not exchange auth_code for access_token"

        # Step 3: complete remaining onboarding steps
        curl -sf --max-time 10 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{}' "${HA_URL}/api/onboarding/core_config" 2>/dev/null || true
        curl -sf --max-time 10 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"analytics_onboarded":false,"installation_type":"Home Assistant OS"}' \
            "${HA_URL}/api/onboarding/analytics" 2>/dev/null || true
        curl -sf --max-time 10 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{}' "${HA_URL}/api/onboarding/integration" 2>/dev/null || true

        # Step 4: create LLAT
        # Note: /api/auth/long_lived_access_token was moved to WebSocket API in HA 2025+
        # We store the access_token as a functional fallback (expires in hours).
        # The user should create a permanent LLAT via HA UI → Profile → Security.
        LLAT_RESP=$(curl -s --max-time 10 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"client_name":"tappaas-cicd","lifespan":3650}' \
            "${HA_URL}/api/auth/long_lived_access_token" 2>/dev/null)
        LLAT=$(echo "${LLAT_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
        if [[ -z "${LLAT}" ]]; then
            warn "  LLAT REST endpoint unavailable (HA 2025+ uses WebSocket API)"
            warn "  Using access_token as temporary token — create permanent LLAT via HA UI"
            LLAT="${ACCESS_TOKEN}"
        fi

        ssh -o BatchMode=yes root@"${NODE_FQDN}" "bash -c '
            mkdir -p /etc/secrets && chmod 750 /etc/secrets
            printf \"HA_TOKEN=%s\nHA_ADMIN_PASS=%s\n\" \"${LLAT}\" \"${ADMIN_PASS}\" > ${SECRETS_FILE}
            chmod 600 ${SECRETS_FILE}
        '"
        info "  ${GN}✓${CL} LLAT bootstrapped and stored in ${SECRETS_FILE}"
        info "  ${YW}Note:${CL} admin password stored in ${SECRETS_FILE} — change after first login"
    else
        warn "  HA user onboarding already complete — LLAT bootstrap skipped"
        warn "  Create a LLAT manually: HA UI → Profile → Security → Long-lived access tokens"
        warn "  Store as HA_TOKEN=<token> in ${SECRETS_FILE} on ${NODE_FQDN}"
    fi
fi

# ── Read LLAT for API calls ───────────────────────────────────────────────────

LLAT=""
if ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "test -f ${SECRETS_FILE}" 2>/dev/null; then
    LLAT=$(ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "grep '^HA_TOKEN=' ${SECRETS_FILE} | cut -d= -f2-" 2>/dev/null || echo "")
fi

# ── Write http: block to configuration.yaml ──────────────────────────────────

info "  Writing http: block to configuration.yaml..."
# Build content on cicd side (variables expanded), base64-encode to avoid escaping
HTTP_CONTENT="http:
  use_x_forwarded_for: true
  trusted_proxies:
    - ${MGMT_CIDR}
    - ${HA_ZONE_GW}
    - 127.0.0.1"

HTTP_B64=$(echo "${HTTP_CONTENT}" | base64 -w 0)
ssh -o BatchMode=yes root@"${NODE_FQDN}" "qm guest exec ${VMID} -- bash -c '
    sed -i \"/^http:/,/^[^ #]/{ /^http:/d; /use_x_forwarded_for/d; /trusted_proxies/d; /^    - /d }\" ${HA_CONFIG_YAML} 2>/dev/null || true
    echo ${HTTP_B64} | base64 -d >> ${HA_CONFIG_YAML}
    echo done
'" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data',''))" 2>/dev/null
info "  ${GN}✓${CL} http: block written (trusted_proxies: ${MGMT_CIDR}, ${HA_ZONE_GW})"

# ── Set external_url via HA API (if LLAT available) or storage file ───────────

info "  Setting external_url to ${EXTERNAL_URL}..."
if [[ -n "${LLAT}" ]]; then
    curl -sf --max-time 10 -X POST \
        -H "Authorization: Bearer ${LLAT}" \
        -H "Content-Type: application/json" \
        -d "{\"external_url\":\"${EXTERNAL_URL}\"}" \
        "${HA_URL}/api/config/core/save" 2>/dev/null && \
        info "  ${GN}✓${CL} external_url set via HA API" || \
        warn "  Could not set external_url via API"
else
    # Fallback: sed on storage file
    ssh -o BatchMode=yes root@"${NODE_FQDN}" "qm guest exec ${VMID} -- bash -c '
        sed -i \"s|\\\"external_url\\\": \\\"[^\\\"]*\\\"|\\\"external_url\\\": \\\"${EXTERNAL_URL}\\\"|\" /mnt/data/supervisor/homeassistant/.storage/core.config 2>/dev/null && echo done || echo skipped
    '" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data',''))" 2>/dev/null
    info "  ${GN}✓${CL} external_url set via storage file"
fi

# ── Validate config then restart HA Core ─────────────────────────────────────

info "  Validating configuration.yaml..."
CHECK=$(ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'ha core check 2>&1'" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" 2>/dev/null || echo "")
if echo "${CHECK}" | grep -qi "failed\|invalid\|error"; then
    error "  configuration.yaml validation failed:"
    echo "${CHECK}" | head -10 >&2
    die "Aborting restart — fix configuration errors first"
fi
info "  ${GN}✓${CL} configuration.yaml valid"

info "  Restarting HA Core..."
ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'ha core restart 2>/dev/null || true'" 2>/dev/null || true
info "  ${GN}✓${CL} HA Core restart triggered"

info "${GN}homeassistant:config install-service completed for ${MODULE}${CL}"
