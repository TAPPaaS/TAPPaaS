#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant Config Service - Install
#
# Configures a fresh HAOS installation for TAPPaaS proxy integration:
#   1. Bootstraps a Long-Lived Access Token via the HA onboarding API
#      (first-run only) and stores it in /etc/secrets/homeassistant.env
#   2. Writes http: block to configuration.yaml (trusted_proxies derived
#      from zones.json + module zone0; no hardcoded IPs)
#   3. Sets external_url in .storage/core.config (derived from proxyDomain)
#   4. Restarts HA Core to apply changes
#
# All values are derived from TAPPaaS SSoT:
#   - tappaas.domain       → configuration.json
#   - vmname, zone0        → {module}.json
#   - proxyDomain          → {module}.json config.firewall:proxy
#   - trusted_proxies CIDRs → zones.json (mgmt + module zone0)
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
readonly HA_STORAGE_CONFIG="/mnt/data/supervisor/homeassistant/.storage/core.config"

# ── Resolve values from SSoT ─────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv_home')"
TAPPAAS_DOMAIN="$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")"

# Proxy domain: explicit or default <vmname>.<domain>
PROXY_DOMAIN="$(get_config_value 'proxyDomain' "${VMNAME}.${TAPPAAS_DOMAIN}")"
EXTERNAL_URL="https://${PROXY_DOMAIN}"

# Trusted proxies: mgmt CIDR (Caddy runs on OPNsense/mgmt) + HA zone gateway
_cidr_gw() { echo "$1" | sed 's|/.*||' | awk -F. '{print $1"."$2"."$3".1"}'; }
MGMT_CIDR="$(jq -r '.mgmt.ip // "10.0.0.0/24"' "${ZONES_FILE}")"
HA_ZONE_CIDR="$(jq -r --arg z "${ZONE0}" '.[$z].ip // empty' "${ZONES_FILE}")"
HA_ZONE_GW="$(_cidr_gw "${HA_ZONE_CIDR:-10.2.10.0/24}")"

NODE_FQDN="${NODE}.mgmt.internal"
HA_IP="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'hostname -I | cut -d\" \" -f1'" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data','').strip())" 2>/dev/null \
    || echo "")"
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
until curl -s --max-time 5 -o /dev/null -w "%{http_code}" "${HA_URL}" 2>/dev/null | grep -qE "^(200|302|401)"; do
    sleep 5; (( local_wait += 5 ))
    [[ $local_wait -lt 180 ]] || die "HA did not become reachable after 180s"
done
info "  ${GN}✓${CL} HA is reachable"

# ── Bootstrap LLAT (first-run onboarding only) ────────────────────────────────

_ha_guest_exec() {
    ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "qm guest exec ${VMID} -- bash -c '$1'" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').rstrip())" 2>/dev/null
}

if ! ssh -o BatchMode=yes root@"${NODE_FQDN}" "test -f ${SECRETS_FILE} && grep -q HA_TOKEN ${SECRETS_FILE}" 2>/dev/null; then
    info "  ${BOLD}Bootstrapping Long-Lived Access Token...${CL}"

    ONBOARD_STATUS=$(curl -sf --max-time 10 "${HA_URL}/api/onboarding" 2>/dev/null || echo "")
    ONBOARD_DONE=$(echo "${ONBOARD_STATUS}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print('done' if all(s.get('done') for s in d) else 'pending')" \
        2>/dev/null || echo "unknown")

    if [[ "${ONBOARD_DONE}" == "pending" ]]; then
        # First run: create admin user via onboarding API
        # Flow: POST /api/onboarding/users → auth_code
        #       POST /auth/token (grant_type=authorization_code) → access_token
        ADMIN_PASS="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))")"
        ONBOARD_RESP=$(curl -sf --max-time 30 -X POST \
            -H "Content-Type: application/json" \
            -d "{\"client_id\":\"http://homeassistant.local/\",\"name\":\"TAPPaaS Admin\",\"username\":\"tappaas\",\"password\":\"${ADMIN_PASS}\",\"language\":\"en\"}" \
            "${HA_URL}/api/onboarding/users" 2>/dev/null)

        AUTH_CODE=$(echo "${ONBOARD_RESP}" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('auth_code',''))" 2>/dev/null)
        [[ -n "${AUTH_CODE}" ]] || die "Onboarding failed — no auth_code in response"

        ACCESS_TOKEN=$(curl -sf --max-time 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=authorization_code&code=${AUTH_CODE}&client_id=http%3A%2F%2Fhomeassistant.local%2F" \
            "${HA_URL}/auth/token" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
        [[ -n "${ACCESS_TOKEN}" ]] || die "Could not exchange auth_code for access_token"

        # Create LLAT from bootstrap token
        LLAT=$(curl -sf --max-time 10 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"client_name":"tappaas-cicd","lifespan":3650}' \
            "${HA_URL}/api/auth/long_lived_access_token" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
        [[ -n "${LLAT}" ]] || die "Could not create Long-Lived Access Token"

        ssh -o BatchMode=yes root@"${NODE_FQDN}" "bash -c '
            mkdir -p /etc/secrets
            chmod 750 /etc/secrets
            printf \"HA_TOKEN=%s\\nHA_ADMIN_PASS=%s\\n\" \"${LLAT}\" \"${ADMIN_PASS}\" > ${SECRETS_FILE}
            chmod 600 ${SECRETS_FILE}
        '"
        info "  ${GN}✓${CL} LLAT bootstrapped and stored in ${SECRETS_FILE}"
        info "  ${YW}Note:${CL} admin password stored in ${SECRETS_FILE} — change after first login"
    else
        warn "  HA onboarding already complete — cannot bootstrap LLAT automatically"
        warn "  Create a Long-Lived Access Token in HA UI → Profile → Security"
        warn "  Then store as HA_TOKEN=<token> in ${SECRETS_FILE} on ${NODE_FQDN}"
    fi
fi

# ── Write http: block to configuration.yaml ──────────────────────────────────

info "  Writing http: block to configuration.yaml..."
_ha_guest_exec "
grep -q 'use_x_forwarded_for' ${HA_CONFIG_YAML} && \
  sed -i '/^http:/,/^[^ ]/{ /^http:/,/trusted_proxies/d; /^  - /d }' ${HA_CONFIG_YAML}
cat >> ${HA_CONFIG_YAML} <<'YAML'
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - ${MGMT_CIDR}
    - ${HA_ZONE_GW}
    - 127.0.0.1
YAML
echo done"
info "  ${GN}✓${CL} http: block written"

# ── Set external_url in .storage/core.config ─────────────────────────────────

info "  Setting external_url to ${EXTERNAL_URL}..."
_ha_guest_exec "
python3 -c \"
import json
with open('${HA_STORAGE_CONFIG}') as f: d = json.load(f)
d['data']['external_url'] = '${EXTERNAL_URL}'
with open('${HA_STORAGE_CONFIG}', 'w') as f: json.dump(d, f)
\"
echo done" || warn "  Could not set external_url (storage file may not exist yet — set manually)"

# ── Restart HA Core ───────────────────────────────────────────────────────────

info "  Restarting HA Core..."
_ha_guest_exec "ha core restart 2>/dev/null || true"
info "  ${GN}✓${CL} HA Core restart triggered"

info "${GN}homeassistant:config install-service completed for ${MODULE}${CL}"
