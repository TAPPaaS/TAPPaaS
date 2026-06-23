#!/usr/bin/env bash
#
# TAPPaaS hass Config Service - Install
#
# Configures a fresh HAOS installation for TAPPaaS proxy integration:
#   1. Bootstraps a Long-Lived Access Token via the HA onboarding API
#      (first-run only) and stores it in /etc/secrets/hass.env
#   2. Completes remaining onboarding steps (core_config, analytics, integration)
#   3. Writes http: block to configuration.yaml (trusted_proxies derived
#      from zones.json + module zone0; no hardcoded IPs)
#   4. Sets external_url via HA API (derived from proxyDomain)
#   5. Restarts HA Core to apply changes
#
# All values derived from TAPPaaS SSoT — no hardcoded IPs or domains:
#   tappaas.domain  → configuration.json
#   vmname, zone0   → {module}.json
#   proxyDomain     → {module}.json config.network:proxy
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
readonly ZONES_FILE="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/manager/network-manager/zones.json"
readonly HA_DATA_DIR="/mnt/data/supervisor/homeassistant"
# Secret store ON the hass VM: persistent (/mnt/data) but OUTSIDE the HA backup
# set (not under supervisor/homeassistant) so the LLAT is not swept into HA
# backups (#344). Same exposure as a native module's /etc/secrets (PBS only).
readonly SECRETS_DIR="/mnt/data/tappaas"
readonly SECRETS_FILE="${SECRETS_DIR}/hass.env"
readonly HA_CONFIG_YAML="${HA_DATA_DIR}/configuration.yaml"

# ── Resolve values from SSoT ─────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srvHome')"
# Domain from the module's environment (config/environments/<env>.json via
# get_variant_config), falling back to legacy configuration.json .tappaas.domain.
_HASS_VARIANT="$(get_config_value 'variant' '')"
TAPPAAS_DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "${_HASS_VARIANT}" 2>/dev/null || echo '{}')")"
[[ -z "${TAPPAAS_DOMAIN}" ]] && TAPPAAS_DOMAIN="$(jq -r '.tappaas.domain // empty' "${SYSTEM_CONFIG}")"
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

# Run a command INSIDE the HAOS guest (via the node's qm guest exec) and echo its
# stdout. Used to read/write the VM-local secret store without SSH (#344).
guest_run() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${NODE_FQDN}" \
        "qm guest exec ${VMID} -- bash -c $(printf '%q' "$1")" 2>/dev/null \
        | python3 -c "import sys,json
try: sys.stdout.write(json.load(sys.stdin).get('out-data',''))
except Exception: pass"
}

info "hass:config install-service for module: ${BL}${MODULE}${CL}"
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

# ── Ensure a durable LLAT on the VM (#344) ───────────────────────────────────
# The LLAT lives ON the hass VM at ${SECRETS_FILE}, minted via the WS API so it
# survives HA Core restarts. Reuse it if still valid; otherwise (fresh onboard)
# mint a fresh one and store it on the VM.

LLAT="$(guest_run "grep '^HA_TOKEN=' ${SECRETS_FILE} 2>/dev/null | cut -d= -f2-" | tr -d '\r\n')"
LLAT_OK=0
if [[ -n "${LLAT}" ]]; then
    _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${LLAT}" "${HA_URL}/api/" 2>/dev/null || echo 000)"
    [[ "${_code}" == "200" ]] && LLAT_OK=1
fi

if [[ "${LLAT_OK}" -eq 1 ]]; then
    info "  ${GN}✓${CL} existing LLAT on the VM is valid — reusing"
else
    info "  ${BOLD}Minting a durable LLAT (WS API) and storing it on the VM...${CL}"
    # Onboarding readiness + detection. Per HA core (onboarding/views.py):
    # GET /api/onboarding returns 200 (no-auth) while onboarding is PENDING; once
    # onboarded the onboarding integration unloads -> 401; a not-yet-ready HA Core
    # also 401s. So a 401 is ambiguous (done OR not-ready) and MUST NOT be read as
    # "done". Poll for a definitive 200 (ready + pending); if it never comes, fall
    # through to the reuse/warn path.
    ONBOARD_READY=0
    for _i in $(seq 1 60); do            # up to ~300s — HAOS first boot can be slow
        _oc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HA_URL}/api/onboarding" 2>/dev/null || echo 000)"
        if [[ "${_oc}" == "200" ]]; then ONBOARD_READY=1; break; fi
        sleep 5
    done

    if [[ "${ONBOARD_READY}" -eq 1 ]]; then
        # First-run onboarding -> admin user -> access_token (auths the WS mint)
        ADMIN_PASS="$(python3 -c "
import secrets,string
print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))
")"
        ONBOARD_RESP=$(curl -sf --max-time 30 -X POST \
            -H "Content-Type: application/json" \
            -d "{\"client_id\":\"http://hass.local/\",\"name\":\"TAPPaaS Admin\",\"username\":\"tappaas\",\"password\":\"${ADMIN_PASS}\",\"language\":\"en\"}" \
            "${HA_URL}/api/onboarding/users" 2>/dev/null)
        AUTH_CODE=$(echo "${ONBOARD_RESP}" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('auth_code',''))" 2>/dev/null)
        [[ -n "${AUTH_CODE}" ]] || die "Onboarding users failed — no auth_code in response"
        ACCESS_TOKEN=$(curl -sf --max-time 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=authorization_code&code=${AUTH_CODE}&client_id=http%3A%2F%2Fhass.local%2F" \
            "${HA_URL}/auth/token" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
        [[ -n "${ACCESS_TOKEN}" ]] || die "Could not exchange auth_code for access_token"
        # complete remaining onboarding steps (best-effort)
        for _step in core_config analytics integration; do
            _body='{}'
            [[ "${_step}" == "analytics" ]] && _body='{"analytics_onboarded":false,"installation_type":"Home Assistant OS"}'
            # The integration step REQUIRES client_id + redirect_uri; with an empty
            # body it stays "not done" and HA keeps redirecting to /onboarding.html
            # (found via principal user-test 2026-06-14).
            [[ "${_step}" == "integration" ]] && _body='{"client_id":"http://hass.local/","redirect_uri":"http://hass.local/"}'
            curl -sf -o /dev/null --max-time 10 -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" -d "${_body}" "${HA_URL}/api/onboarding/${_step}" 2>/dev/null || true
        done
        # Mint a DURABLE LLAT via the WS API (idempotent: revoke-then-mint)
        LLAT="$(HA_ACCESS_TOKEN="${ACCESS_TOKEN}" bash "${SCRIPT_DIR}/ha-llat.sh" "${HA_IP}" tappaas-cicd 3650)" \
            || die "Durable LLAT mint via WS failed"
        [[ -n "${LLAT}" ]] || die "Durable LLAT mint returned empty"
        # Store on the VM (persistent, outside HA backups), mode 600
        _secret_b64="$(printf 'HA_TOKEN=%s\nHA_ADMIN_PASS=%s\n' "${LLAT}" "${ADMIN_PASS}" | base64 -w0)"
        guest_run "mkdir -p ${SECRETS_DIR} && echo ${_secret_b64} | base64 -d > ${SECRETS_FILE} && chmod 600 ${SECRETS_FILE} && echo WROTE" | grep -q WROTE \
            || die "Could not write ${SECRETS_FILE} on the VM"
        info "  ${GN}✓${CL} durable LLAT minted (WS) + stored on the VM at ${SECRETS_FILE} (mode 600)"
        info "  ${YW}Note:${CL} admin password also stored there — change after first login"
    else
        warn "  Onboarding not READY (no HTTP 200 from /api/onboarding within 300s) —"
        warn "  HA is likely already onboarded, or HA Core is unhealthy. A fresh mint needs an"
        warn "  onboarding token: create an LLAT in HA UI -> Profile -> Security and store it as"
        warn "  HA_TOKEN= in ${SECRETS_FILE} on the VM, or --reinstall for a clean bootstrap."
        LLAT=""
    fi
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

# ── Set internal_url + external_url via the WS API (config/core/update) ────────
# Lesson from hassanova (2026-06-13 incident): internal_url MUST be the DIRECT LAN
# URL, NOT the proxy domain — else internal access couples to the external
# proxy/firewall and breaks with it. external_url = the proxy domain (for SSO).
# REST /api/config/core/save returns 404; the WS API is the authoritative path.
INTERNAL_URL="http://${VMNAME}.${ZONE0}.internal:8123"
info "  Setting URLs (WS API): internal_url=${INTERNAL_URL}  external_url=${EXTERNAL_URL}"
if [[ -n "${LLAT}" ]] && HA_TOKEN="${LLAT}" bash "${SCRIPT_DIR}/ha-ws.sh" "${HA_IP}" \
        "$(printf '{"type":"config/core/update","internal_url":"%s","external_url":"%s"}' "${INTERNAL_URL}" "${EXTERNAL_URL}")" >/dev/null 2>&1; then
    info "  ${GN}✓${CL} internal_url + external_url set via WS API"
else
    warn "  Could not set internal_url/external_url via WS — set them in HA UI (Settings > System > Network)"
fi

# ── Validate config then restart HA Core ─────────────────────────────────────

info "  Validating configuration.yaml..."
# Retry check up to 3 times — Supervisor may be busy with init jobs
CHECK=""; _tries=0
until [[ $_tries -ge 3 ]]; do
    CHECK=$(ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "qm guest exec ${VMID} -- bash -c 'ha core check 2>&1'" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" 2>/dev/null || echo "")
    # "Another job is running" is a transient Supervisor lock, not a config error
    echo "${CHECK}" | grep -qi "Another job is running" && { _tries=$(( _tries + 1 )); sleep 15; continue; }
    break
done
if echo "${CHECK}" | grep -qi "failed\|invalid"; then
    error "  configuration.yaml validation failed:"
    echo "${CHECK}" | head -10 >&2
    die "Aborting restart — fix configuration errors first"
fi
info "  ${GN}✓${CL} configuration.yaml valid"

info "  Restarting HA Core to load configuration.yaml (http: reverse-proxy block)..."
# Must NOT be fire-and-forget: if the restart is swallowed, HA runs WITHOUT the
# http: block (trusted_proxies) and rejects the reverse proxy with 400 (found via
# user-test 2026-06-14). Retry past a busy Supervisor, then WAIT for HA to return.
_rs=0
for _i in 1 2 3; do
    _rout="$(ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "qm guest exec ${VMID} --timeout 120 -- bash -c 'ha core restart 2>&1'" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data','').strip())" 2>/dev/null || echo "")"
    echo "${_rout}" | grep -qi "Another job is running" && { sleep 15; continue; }
    _rs=1; break
done
[[ "${_rs}" -eq 1 ]] || warn "  ha core restart kept hitting a busy Supervisor — verify manually"
info "  Waiting for HA Core to come back (http: block live)..."
_back=0
for _i in $(seq 1 36); do        # up to ~180s
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HA_URL}" 2>/dev/null || echo 000)"
    [[ "${_c}" == "200" || "${_c}" == "302" || "${_c}" == "401" ]] && { _back=1; break; }
    sleep 5
done
[[ "${_back}" -eq 1 ]] && info "  ${GN}✓${CL} HA Core back up — reverse-proxy config loaded" \
    || warn "  HA Core not confirmed back up after 180s — check manually"

info "${GN}hass:config install-service completed for ${MODULE}${CL}"
