#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — Installation
#
# Deploys the Jellyfin NixOS config, provisions the media disk, and bootstraps
# three pre-made user accounts (admin, stream, local). VM creation is handled
# by the cluster:vm dependency. Media disk provisioning (services/mediaserver)
# runs here since it provisions jellyfin's own infrastructure, not a consumer VM.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Provision the media disk (allocate on Proxmox, format, mount /media)
"${SCRIPT_DIR}/services/mediaserver/install-service.sh"

# Apply the NixOS config (also run on updates)
. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-jellyfin}")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
JELLYFIN_URL="http://${JELLYFIN_HOST}:8096"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

# jf_call METHOD PATH DATA [curl-args...] — POST/GET the Jellyfin API. Prints
# the response body to stdout regardless of outcome (for jq to consume), warns
# on stderr with the real HTTP status/body on failure, and returns non-zero.
# curl -sf swallows the HTTP status and body on failure, which turns every
# bootstrap error into a silent `set -e` exit with no clue why.
jf_call() {
    local method="$1" path="$2" data="$3" resp status body
    shift 3
    resp=$(curl -sS -X "$method" "${JELLYFIN_URL}${path}" \
        -H "Content-Type: application/json" -d "$data" "$@" \
        -w $'\n%{http_code}')
    status="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    printf '%s' "$body"
    if [[ ! "$status" =~ ^2 ]]; then
        warn "  ${method} ${path} failed (HTTP ${status}): ${body}" >&2
        return 1
    fi
}

# ── Wait for Jellyfin API ─────────────────────────────────────────────────────
echo ""
info "${BOLD}Waiting for Jellyfin API...${CL}"
for i in $(seq 1 30); do
    if curl -sf "${JELLYFIN_URL}/health" >/dev/null 2>&1; then
        info "  ${GN}✓${CL} Jellyfin API ready"
        break
    fi
    [[ $i -eq 30 ]] && { warn "  Jellyfin API did not respond after 60s — skipping user setup"; exit 0; }
    sleep 2
done

# ── Bootstrap admin via startup wizard ───────────────────────────────────────
# Only runs if the startup wizard has not been completed yet.
STARTUP_STATUS=$(curl -sf "${JELLYFIN_URL}/Startup/Configuration" \
    -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
    2>/dev/null | jq -r '.StartupWizardCompleted // false' 2>/dev/null || echo "false")

if [[ "${STARTUP_STATUS}" == "false" ]]; then
    info "${BOLD}Bootstrapping Jellyfin users...${CL}"

    # /health responds as soon as Kestrel starts listening, but Jellyfin creates
    # its default startup user a few seconds later during internal startup
    # tasks. /Startup/User calls UserManager.Users.First() and throws
    # "Sequence contains no elements" if hit before that user exists.
    for i in $(seq 1 15); do
        curl -sf "${JELLYFIN_URL}/Startup/User" \
            -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
            >/dev/null 2>&1 && break
        [[ $i -eq 15 ]] && warn "  Default startup user never became available — proceeding anyway"
        sleep 1
    done

    ADMIN_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))")

    INSTALL_AUTH_HEADER='X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"'

    # Complete startup wizard
    jf_call POST /Startup/User "{\"Name\":\"admin\",\"Password\":\"${ADMIN_PASS}\"}" \
        -H "$INSTALL_AUTH_HEADER" >/dev/null

    jf_call POST /Startup/Complete "" -H "$INSTALL_AUTH_HEADER" >/dev/null 2>&1 || true

    info "  ${GN}✓${CL} Admin account created"

    # Authenticate to get token
    TOKEN=$(jf_call POST /Users/AuthenticateByName "{\"Username\":\"admin\",\"Pw\":\"${ADMIN_PASS}\"}" \
        -H "$INSTALL_AUTH_HEADER" | jq -r '.AccessToken')

    AUTH_HEADER="X-Emby-Authorization: MediaBrowser Token=\"${TOKEN}\""

    # ── stream user: transcoding on, client-adaptive bitrate, remote access allowed
    STREAM_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))")
    STREAM_ID=$(jf_call POST /Users/New "{\"Name\":\"stream\",\"Password\":\"${STREAM_PASS}\"}" \
        -H "$AUTH_HEADER" | jq -r '.Id')

    jf_call POST "/Users/${STREAM_ID}/Policy" '{
          "IsAdministrator": false,
          "AuthenticationProviderId": "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider",
          "PasswordResetProviderId": "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider",
          "EnableVideoPlaybackTranscoding": true,
          "EnableAudioPlaybackTranscoding": true,
          "EnablePlaybackRemuxing": true,
          "MaxStreamingBitrate": 0,
          "RemoteClientBitrateLimit": 0,
          "EnableRemoteAccess": true,
          "EnableAllFolders": true,
          "EnableMediaPlayback": true
        }' -H "$AUTH_HEADER" >/dev/null

    info "  ${GN}✓${CL} 'stream' user created (transcoding on, remote access allowed)"

    # ── local user: direct play only, no transcoding, no remote access
    LOCAL_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))")
    LOCAL_ID=$(jf_call POST /Users/New "{\"Name\":\"local\",\"Password\":\"${LOCAL_PASS}\"}" \
        -H "$AUTH_HEADER" | jq -r '.Id')

    jf_call POST "/Users/${LOCAL_ID}/Policy" '{
          "IsAdministrator": false,
          "AuthenticationProviderId": "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider",
          "PasswordResetProviderId": "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider",
          "EnableVideoPlaybackTranscoding": false,
          "EnableAudioPlaybackTranscoding": false,
          "EnablePlaybackRemuxing": true,
          "MaxStreamingBitrate": 0,
          "RemoteClientBitrateLimit": 0,
          "EnableRemoteAccess": false,
          "EnableAllFolders": true,
          "EnableMediaPlayback": true
        }' -H "$AUTH_HEADER" >/dev/null

    info "  ${GN}✓${CL} 'local' user created (direct play only, internal network only)"

    # Store credentials for the summary print
    _ADMIN_PASS="${ADMIN_PASS}"
    _STREAM_PASS="${STREAM_PASS}"
    _LOCAL_PASS="${LOCAL_PASS}"
else
    info "  Startup wizard already completed — skipping user bootstrap"
    _ADMIN_PASS="(already set)"
    _STREAM_PASS="(already set)"
    _LOCAL_PASS="(already set)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
_DOMAIN=$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)

echo ""
info "${GN}✓${CL} Jellyfin installation completed."
if [[ -n "${_DOMAIN}" ]]; then
    info "  Web UI : https://${VMNAME}.${_DOMAIN}"
else
    info "  Web UI : http://${JELLYFIN_HOST}:8096"
fi
echo ""
info "${BOLD}Pre-made accounts (change passwords after first login):${CL}"
info "  admin   / ${_ADMIN_PASS}   — full admin"
info "  stream  / ${_STREAM_PASS}  — remote/family, transcoding on, adaptive bitrate"
info "  local   / ${_LOCAL_PASS}   — internal only, direct play, no transcoding (Infuse/Apple TV)"
echo ""
info "  Add libraries in Dashboard → Libraries:"
info "    /media/Movies      → type: Movies"
info "    /media/TV          → type: Shows"
info "    /media/Music       → type: Music"
info "    /media/Photos      → type: Photos"
info "    /media/Audiobooks  → type: Books/Audiobooks"
