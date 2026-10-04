#!/usr/bin/env bash
# TAPPaaS Module: immich — Installation
#
# Deploys the Immich NixOS config, provisions the photo data disk, and
# bootstraps the admin account. VM creation is handled by the cluster:vm
# dependency. Data disk provisioning (services/photostorage) runs here since
# it provisions immich's own infrastructure, not a consumer VM.
#
# Security note: the admin account is claimed immediately after the API comes
# up — /api/auth/admin-sign-up is open to anyone until the first admin exists,
# so this closes that window within the same install run. The generated
# password is printed once and never written to disk.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Provision the data disk (allocate on Proxmox, format, mount /var/lib/immich)
"${SCRIPT_DIR}/services/photostorage/install-service.sh"

# Apply the NixOS config (also run on updates)
. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-immich}")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
IMMICH_URL="http://${IMMICH_HOST}:2283"

# ── Wait for Immich API ───────────────────────────────────────────────────────
# Generous timeout (5 min): first boot runs DB migrations before the API is up.
# Failing here MUST be loud and non-zero — until the admin account is claimed,
# /api/auth/admin-sign-up accepts anyone, and the Caddy route (incl. the
# internet zone) already exists at this point.
echo ""
info "${BOLD}Waiting for Immich API...${CL}"
for i in $(seq 1 150); do
    if curl -sf "${IMMICH_URL}/api/server/ping" 2>/dev/null | grep -q pong; then
        info "  ${GN}✓${CL} Immich API ready"
        break
    fi
    if [[ $i -eq 150 ]]; then
        warn "  Immich API did not respond after 5 minutes."
        warn "  ${RD}${BOLD}SECURITY: the admin account has NOT been claimed — the public${CL}"
        warn "  ${RD}${BOLD}sign-up endpoint stays open until it is. Diagnose the VM${CL}"
        warn "  ${RD}${BOLD}(journalctl -u immich-server) and RE-RUN ./install.sh NOW.${CL}"
        exit 1
    fi
    sleep 2
done

# ── Bootstrap admin account ───────────────────────────────────────────────────
# /api/auth/admin-sign-up succeeds (HTTP 201) only while no admin exists;
# afterwards it returns 400 — used as the "already initialized" signal.
_DOMAIN=$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)
ADMIN_EMAIL="admin@${_DOMAIN:-tappaas.internal}"

info "${BOLD}Bootstrapping Immich admin account...${CL}"
ADMIN_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))")

# Password is piped via stdin (-d @-) so it never appears in the process list.
HTTP_CODE=$(printf '{"name":"Admin","email":"%s","password":"%s"}' "${ADMIN_EMAIL}" "${ADMIN_PASS}" \
    | curl -s -o /dev/null -w '%{http_code}' -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null || echo 000)

if [[ "${HTTP_CODE}" == "201" ]]; then
    info "  ${GN}✓${CL} Admin account created (${ADMIN_EMAIL})"
    _ADMIN_PASS="${ADMIN_PASS}"

    # ── Mint an API key for the identity:identity OIDC automation ────────────
    # The admin PASSWORD is deliberately never written to disk (see the
    # security note above); immich-configure-oidc.service instead uses a
    # narrowly-scoped, revocable API key, minted now while we still hold
    # fresh credentials (a re-run after the admin already exists cannot do
    # this — see the else branch below).
    info "${BOLD}Minting an API key for OIDC automation...${CL}"
    ACCESS_TOKEN=$(printf '{"email":"%s","password":"%s"}' "${ADMIN_EMAIL}" "${ADMIN_PASS}" \
        | curl -s -X POST "${IMMICH_URL}/api/auth/login" \
            -H "Content-Type: application/json" -d @- 2>/dev/null \
        | jq -r '.accessToken // empty')

    API_KEY=""
    if [[ -n "${ACCESS_TOKEN}" ]]; then
        API_KEY=$(printf '{"name":"identity-automation","permissions":["systemConfig.read","systemConfig.update"]}' \
            | curl -s -X POST "${IMMICH_URL}/api/api-keys" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" -d @- 2>/dev/null \
            | jq -r '.secret // empty')
        # The login session token was only ever needed for this one call —
        # invalidate it now so it can't be replayed later (best-effort: a
        # missed logout just leaves a session to expire on its own).
        curl -s -X POST "${IMMICH_URL}/api/auth/logout" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" >/dev/null 2>&1 || true
    else
        warn "  Could not log in as the fresh admin — OIDC automation will not activate."
    fi

    if [[ -n "${API_KEY}" ]]; then
        ssh-keygen -R "${IMMICH_HOST}" >/dev/null 2>&1 || true
        if printf '%s' "${API_KEY}" | ssh -o BatchMode=yes -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new "tappaas@${IMMICH_HOST}" \
            "sudo install -d -m 700 /etc/secrets && \
             sudo sh -c 'umask 077; cat > /etc/secrets/immich-admin-api-key' && \
             sudo chmod 600 /etc/secrets/immich-admin-api-key"; then
            info "  ${GN}✓${CL} API key written to /etc/secrets/immich-admin-api-key on ${IMMICH_HOST}"
        else
            warn "  Could not write the API key to ${IMMICH_HOST} — OIDC automation will not activate."
            warn "  Create one manually (Account Settings → API Keys, permissions"
            warn "  systemConfig.read + systemConfig.update) and place it at"
            warn "  /etc/secrets/immich-admin-api-key on the VM (mode 600)."
        fi
    elif [[ -n "${ACCESS_TOKEN}" ]]; then
        warn "  Could not create an API key — OIDC automation will not activate."
    fi

    # If identity:identity already wrote the OIDC secrets (dependency installed
    # before this script ran), activate the configure service immediately
    # rather than waiting for the next boot.
    if [[ -n "${API_KEY}" ]] && ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${IMMICH_HOST}" \
        "sudo test -f /etc/secrets/immich.env" 2>/dev/null; then
        info "  OIDC secrets already present — activating immich-configure-oidc.service now"
        ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${IMMICH_HOST}" \
            "sudo systemctl restart immich-configure-oidc.service" \
            || warn "  could not restart immich-configure-oidc.service — it will retry on next boot"
    fi
else
    info "  Admin account already exists (HTTP ${HTTP_CODE}) — skipping bootstrap"
    ADMIN_EMAIL="(already set)"
    _ADMIN_PASS="(already set)"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${IMMICH_HOST}" \
        "sudo test -f /etc/secrets/immich-admin-api-key" 2>/dev/null; then
        warn "  No API key at /etc/secrets/immich-admin-api-key on ${IMMICH_HOST} — OIDC"
        warn "  automation (immich-configure-oidc.service) will not activate. Create one"
        warn "  in the admin UI (Account Settings → API Keys, permissions systemConfig.read"
        warn "  + systemConfig.update), then place it at /etc/secrets/immich-admin-api-key"
        warn "  on the VM (mode 600)."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "${GN}✓${CL} Immich installation completed."
if [[ -n "${_DOMAIN}" ]]; then
    info "  Web UI : https://${VMNAME}.${_DOMAIN}"
else
    info "  Web UI : http://${IMMICH_HOST}:2283"
fi
echo ""
info "${BOLD}Admin account (change the password after first login):${CL}"
info "  ${ADMIN_EMAIL} / ${_ADMIN_PASS}"
echo ""
info "Next steps:"
info "  - Mobile app: install 'Immich' (iOS/Android), enter the Web UI URL, log in"
info "    → background photo/video auto-upload works from anywhere"
info "  - SSO: identity:identity wires Authentik automatically (users group, all"
info "    logged-in members) — a 'Login with OAuth' button appears once its"
info "    install-service.sh has run; see INSTALL.md → Authentik OIDC for the"
info "    manual fallback if the API key couldn't be minted above"
info "  - Smart search & face recognition run automatically as photos arrive"
info "    (first job downloads ML models, ~1-2 GB)"
