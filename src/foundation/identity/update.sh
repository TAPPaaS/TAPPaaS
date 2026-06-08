#!/usr/bin/env bash
#
# TAPPaaS Identity VM update / install (idempotent).
#
# Beyond reading config, this script does Phase B of issue #45 — the one-time
# Authentik+Caddy "global" wiring needed before any module's identity:
# accessControl can attach a forward-auth app to the embedded outpost:
#
#   1. Wait for Authentik's API to come up on the identity VM
#   2. Read AUTHENTIK_BOOTSTRAP_TOKEN from /etc/secrets/authentik.env (created
#      on first boot by identity.nix's generate-authentik-secrets service)
#   3. Persist it to ~/.authentik-credentials.txt on the cicd (mode 600) so
#      authentik-manager can talk to Authentik
#   4. Configure Caddy's global AuthProvider = Authentik, point it at the
#      identity outpost, and register the 12 X-Authentik-* copy-headers
#      operators previously added by hand in the GUI
#   5. Set the embedded outpost's authentik_host to the public identity URL
#   6. Create/update the identity self-application + Proxy Provider and attach
#      it to the embedded outpost (so https://identity.<domain>/outpost.* works)
#
# Re-running is safe: every step is reconcile-in-place.
#
# Usage: ./update.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# Shared Authentik credential bootstrap helper (issue #312) — single source of
# truth for materialising ~/.authentik-credentials.txt from the identity VM.
IDENTITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ensure-authentik-creds.sh disable=SC1091
. "${IDENTITY_DIR}/lib/ensure-authentik-creds.sh"

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
DOMAIN="$(jq -r '.tappaas.domain // empty' "$CONFIG_FILE" 2>/dev/null)"
[[ -n "$DOMAIN" && "$DOMAIN" != CHANGE* ]] || die "tappaas.domain not set in ${CONFIG_FILE}"

IDENTITY_FQDN="${VMNAME}.${ZONE0NAME}.internal"
IDENTITY_PUBLIC="https://identity.${DOMAIN}"
# ~/.authentik-credentials.txt (url=http://${IDENTITY_FQDN}:9000 + token=) is
# materialised by ensure_authentik_credentials below (shared helper, #312).
FIREWALL_FQDN="firewall.mgmt.internal"
OPNSENSE_CREDS="${HOME}/.opnsense-credentials.txt"

info "${BOLD}Post-Install / Update Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"

# ── Phase B step 1-4: bootstrap + verify the cicd-side Authentik credentials ─
# Waits for the Authentik API, fetches AUTHENTIK_BOOTSTRAP_TOKEN from the
# identity VM, writes ~/.authentik-credentials.txt (mode 600), and polls until
# the token is accepted. Shared with accessControl/install-service.sh so a
# consumer install self-heals when the credential is missing/stale (#312).
ensure_authentik_credentials

# ── Phase B step 5-6: Caddy global AuthProvider + 12 X-Authentik-* headers ──

[[ -f "$OPNSENSE_CREDS" ]] || die "OPNsense credentials file missing: $OPNSENSE_CREDS"
OPNSENSE_KEY="$(grep '^key=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_SECRET="$(grep '^secret=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_AUTH="${OPNSENSE_KEY}:${OPNSENSE_SECRET}"
OPNSENSE_API="https://${FIREWALL_FQDN}:8443/api/caddy"

info "${BOLD}Configuring Caddy global AuthProvider = Authentik${CL}"
# NB: AuthToTls (OptionField) rejects every value form I tried — "http://",
# "http", "1" all → "Option [] not in list" (caddy/general/set bug?). The
# default is "http://" which is what we want for the Authentik outpost on the
# internal mgmt network anyway. Skip it; leave the default.
# `general/set` is partial-replace (doesn't wipe missing fields), so a second
# call below for CopyHeaders won't clobber what we set here.
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/general/set" \
    -H 'Content-Type: application/json' \
    -d "{\"caddy\":{\"general\":{\
\"AuthProvider\":\"authentik\",\
\"AuthToDomain\":\"${IDENTITY_FQDN}\",\
\"AuthToPort\":\"9000\",\
\"AuthToUri\":\"/outpost.goauthentik.io/auth/caddy\"\
}}}" | jq -r .result >/dev/null || die "Failed to set Caddy AuthProvider"
info "  ${GN}✓${CL} AuthProvider set → ${IDENTITY_FQDN}:9000 /outpost.goauthentik.io/auth/caddy"

# The 12 X-Authentik-* headers per the issue. We add each only if absent
# (HeaderType is the natural key — case-sensitive, must match Authentik's).
AUTHENTIK_HEADERS=(
    X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements
    X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt
    X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider
    X-Authentik-Meta-App X-Authentik-Meta-Version
)
info "${BOLD}Ensuring 12 X-Authentik-* copy-headers (Caddy header model)${CL}"
# Snapshot existing rows once
EXISTING_HEADERS="$(curl -ksS -u "$OPNSENSE_AUTH" "${OPNSENSE_API}/ReverseProxy/searchHeader")"
declare -a HEADER_UUIDS=()
for h in "${AUTHENTIK_HEADERS[@]}"; do
    uuid="$(echo "$EXISTING_HEADERS" | jq -r --arg h "$h" '.rows[] | select(.HeaderType==$h) | .uuid' | head -1)"
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        body="$(printf '{"header":{"enabled":"1","HeaderUpDown":"header_up","HeaderType":"%s","HeaderValue":"","HeaderReplace":"","description":"TAPPaaS forward-auth header (#45)"}}' "$h")"
        uuid="$(curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/ReverseProxy/addHeader" \
            -H 'Content-Type: application/json' -d "$body" | jq -r '.uuid // empty')"
        [[ -n "$uuid" ]] || die "Failed to create Caddy header ${h}"
        info "    + ${h} (new uuid=${uuid:0:8})"
    fi
    HEADER_UUIDS+=("$uuid")
done

# Attach all 12 UUIDs to general.CopyHeaders (comma-separated; idempotent set).
COPY_HEADERS_CSV="$(IFS=,; echo "${HEADER_UUIDS[*]}")"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/general/set" \
    -H 'Content-Type: application/json' \
    -d "{\"caddy\":{\"general\":{\"CopyHeaders\":\"${COPY_HEADERS_CSV}\"}}}" | jq -r .result >/dev/null \
    || die "Failed to attach CopyHeaders"
info "  ${GN}✓${CL} CopyHeaders attached (${#HEADER_UUIDS[@]} headers)"

info "${BOLD}Applying Caddy config${CL}"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/service/reconfigure" | jq -r .status >/dev/null
ssh -o StrictHostKeyChecking=accept-new "root@${FIREWALL_FQDN}" "/bin/sh -c 'configctl caddy reload'" >/dev/null 2>&1 || true

# ── Phase B step 7-8: outpost + identity self-app ───────────────────────────

info "${BOLD}Configuring the Authentik embedded outpost (authentik_host=${IDENTITY_PUBLIC})${CL}"
authentik-manager outpost-set-authentik-host "${IDENTITY_PUBLIC}"

info "${BOLD}Registering the identity self-app (so the outpost endpoint works on identity.<domain>)${CL}"
authentik-manager proxy-app-ensure identity \
    --name identity \
    --external-host "${IDENTITY_PUBLIC}" \
    --description "TAPPaaS identity self-app (#45)" \
    --attach-outpost

# ── ADR-006: reconcile the baseline role groups (Installer + default + variants) ─
# Idempotent — creates tappaas-installers and the default `tappaas` scope groups,
# plus a scope per registered variant. Safe to skip if not yet deployed.
info "${BOLD}Reconciling Authentik role groups (ADR-006)${CL}"
if [[ -x /home/tappaas/bin/roles-ensure.sh ]]; then
    /home/tappaas/bin/roles-ensure.sh || warn "roles-ensure reported an error — role groups may be incomplete"
else
    warn "roles-ensure.sh not in ~/bin yet (run update-tappaas to deploy it); skipping role-group reconcile"
fi

echo
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"
info "  Authentik UI : ${IDENTITY_PUBLIC}"
info "  Admin login  : akadmin / (see /etc/secrets/authentik.env on ${IDENTITY_FQDN}: AUTHENTIK_BOOTSTRAP_PASSWORD)"
info "  Per-app SSO  : every consumer with dependsOn: identity:accessControl gets forward-auth wired automatically"
