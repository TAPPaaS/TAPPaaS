#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — Verification Tests
#
# Runs health checks for the Jellyfin installation.
# Must be run from tappaas-cicd as the tappaas user.
#
# Usage: ./test.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-jellyfin}" 2>/dev/null || true

_VMNAME="$(get_config_value 'vmname' 'jellyfin' 2>/dev/null || echo 'jellyfin')"
_ZONE="$(get_config_value 'zone0' 'srvHome' 2>/dev/null || echo 'srvHome')"
TARGET="${_VMNAME}.${_ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/jellyfin-test-${TIMESTAMP}.log"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' BL='\033[34m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0 SKIPPED=0
mkdir -p "$LOG_DIR"

log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
pass()   { log "${GN}[PASS]${CL} $1"; PASSED=$((PASSED + 1)); }
fail()   { log "${RD}[FAIL]${CL} $1"; FAILED=$((FAILED + 1)); }
skip()   { log "${YW}[SKIP]${CL} $1"; SKIPPED=$((SKIPPED + 1)); }
inf()    { log "${BL}[INFO]${CL} $1"; }
header() { log ""; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; log "${BOLD}  $1${CL}"; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; }
remote() { $SSH_CMD "$1" 2>/dev/null; }

[[ "$(hostname)" == "tappaas-cicd" ]] || { echo -e "${RD}[ERROR]${CL} Run this on tappaas-cicd."; exit 1; }

header "TAPPaaS Jellyfin Verification Tests"
log "Timestamp : $(date)"
log "Target    : tappaas@${TARGET}"
log "Log file  : ${LOG_FILE}"

inf "Checking connectivity to ${TARGET}..."
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi
inf "Connection established."

# ── Test 1: Jellyfin service ──────────────────────────────────────────────────
header "Test 1: Jellyfin Service"
JF_STATUS=$(remote "systemctl is-active jellyfin 2>/dev/null || echo inactive")
if [[ "${JF_STATUS}" == "active" ]]; then
    pass "jellyfin service is active"
else
    fail "jellyfin service is ${JF_STATUS}"
fi

# ── Test 2: HTTP health endpoint ──────────────────────────────────────────────
header "Test 2: HTTP Health Endpoint"
HTTP_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8096/health 2>/dev/null || echo 000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pass "Jellyfin /health returned HTTP 200"
elif [[ "${HTTP_CODE}" == "301" || "${HTTP_CODE}" == "302" ]]; then
    pass "Jellyfin /health returned HTTP ${HTTP_CODE} (redirect — server is up)"
else
    fail "Jellyfin /health returned HTTP ${HTTP_CODE}"
fi
_WANT="$(get_config_value 'appVersion' '' 2>/dev/null || true)"
_HAVE="$(remote "curl -s --max-time 10 http://localhost:8096/System/Info/Public" | jq -r '.Version // empty' 2>/dev/null || true)"
if [[ -z "${_WANT}" ]]; then
    skip "no appVersion in the module config to compare with (running ${_HAVE:-unknown})"
elif [[ "${_HAVE}" == "${_WANT}" || "${_HAVE}" == "${_WANT}".* ]]; then
    pass "Jellyfin ${_HAVE} runs (appVersion ${_WANT})"
else
    fail "Jellyfin ${_HAVE:-unknown} runs, appVersion is ${_WANT}"
fi

# ── Test 3: Media share (storage:nfs) ─────────────────────────────────────────
# /media is the share "media" (subdir jellyfin) once a server declares it. Until
# then the mount is PENDING (ADR-029 v0.8): /media is a directory on this VM's
# disk — a valid state, so this check is skipped, not failed. A mount in the
# guest's fstab means the share is available, and then it must be mounted.
header "Test 3: Media Share"
# What is mounted decides first: a migration mounts the share at once, before
# the next build writes it into the guest's fstab. `ls` triggers an automount.
MEDIA_SRC=$(remote "ls /media >/dev/null 2>&1; findmnt -n -t nfs,nfs4 -o SOURCE /media 2>/dev/null | tail -1 || true")
if [[ -n "${MEDIA_SRC}" ]]; then
    pass "/media is the NFS share ${MEDIA_SRC}"
    inf "  $(remote "df -h /media | tail -1" || true)"
elif [[ "$(remote "findmnt -n --fstab /media >/dev/null && echo yes || echo no")" == "yes" ]]; then
    fail "/media is declared as the media share but not mounted — is its server up? (storage-manager nfs show, then update-module.sh jellyfin)"
else
    skip "media share not mounted: pending (no share 'media' declared) or migration awaiting consent — /media is on this VM's disk (storage:nfs test-service says which)"
fi

# ── Test 4: Library folders (share or local) ──────────────────────────────────
header "Test 4: Library Folders"
FOLDERS_OK=$(remote "test -d /media/Movies && test -d /media/TV && test -d /media/Music && echo yes || echo no")
if [[ "${FOLDERS_OK}" == "yes" ]]; then
    pass "Library folders exist (Movies, TV, Music)"
else
    fail "One or more library folders missing — update.sh creates them"
fi

# ── Test 5: Jellyfin can write to /media ──────────────────────────────────────
# On the share every request is squashed to its owner (ADR-029 D7), so the
# jellyfin user writes there although the files belong to another uid.
header "Test 5: /media Writable by Jellyfin"
WRITE_OK=$(remote "f=/media/.tappaas-write-test.\$\$; sudo -u jellyfin touch \"\$f\" 2>/dev/null && sudo -u jellyfin rm -f \"\$f\" && echo yes || echo no")
if [[ "${WRITE_OK}" == "yes" ]]; then
    pass "jellyfin can write to /media"
else
    fail "jellyfin cannot write to /media — on the share it must be granted rw"
fi

# ── Test 6: Sign in with Authentik (SSO-Auth plugin, #806) ────────────────────
# identity:identity writes /etc/secrets/jellyfin.env only when Jellyfin is
# published; without it there is no provider to configure, so skip.
header "Test 6: Sign in with Authentik"
if [[ "$(remote "test -f /etc/secrets/jellyfin.env && echo yes || echo no")" != "yes" ]]; then
    skip "no OIDC config on the VM (/etc/secrets/jellyfin.env) — Jellyfin is not published, or identity:identity has not run"
else
    # Jellyfin 12 no longer records a loaded plugin's status in its meta.json;
    # one it refused (Disabled, NotSupported, Malfunctioned, ...) still does.
    # That the plugin serves requests is the redirect check below.
    PLUGIN_META=$(remote "sudo sh -c 'cat /var/lib/jellyfin/plugins/SSO-Auth_*/meta.json' 2>/dev/null | jq -r '\"\(.version) \(.status // \"none\")\"' | head -1")
    PLUGIN_WANT=$(remote "sudo sh -c 'cat /var/lib/jellyfin/plugins/SSO-Auth_*/.tappaas-src' 2>/dev/null" | grep -oE 'jellyfin-plugin-sso-[0-9.]+' | head -1 | sed 's/jellyfin-plugin-sso-//')
    if [[ -z "${PLUGIN_META}" ]]; then
        fail "SSO-Auth plugin is not installed (no plugins/SSO-Auth_*/meta.json)"
    elif [[ "${PLUGIN_META#* }" != "Active" && "${PLUGIN_META#* }" != "none" ]]; then
        fail "SSO-Auth plugin ${PLUGIN_META% *} was not loaded (status ${PLUGIN_META#* }) — see journalctl -u jellyfin"
    elif [[ -n "${PLUGIN_WANT}" && "${PLUGIN_META% *}" != "${PLUGIN_WANT}" ]]; then
        fail "SSO-Auth plugin ${PLUGIN_META% *} is installed, the configuration pins ${PLUGIN_WANT}"
    else
        pass "SSO-Auth plugin ${PLUGIN_META% *} is installed and not refused"
    fi
    CONF_STATE=$(remote "systemctl is-active jellyfin-configure-oidc 2>/dev/null || true")
    if [[ "${CONF_STATE}" == "active" ]]; then
        pass "jellyfin-configure-oidc has written the provider"
    else
        fail "jellyfin-configure-oidc is ${CONF_STATE:-unknown} — see journalctl -u jellyfin-configure-oidc"
    fi
    # The plugin answers the start of the login with a redirect to Authentik's
    # authorize endpoint only when the provider is configured and enabled.
    START=$(remote "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 http://localhost:8096/sso/OID/start/authentik")
    if [[ "${START}" == 302*"/application/o/authorize"* ]]; then
        pass "/sso/OID/start/authentik redirects to Authentik"
    else
        fail "/sso/OID/start/authentik did not redirect to Authentik (${START:-no answer})"
    fi
    # Jellyfin accepts the empty password for an account without one, and the
    # plugin before 5.x created SSO accounts without one. 5.x seals them at
    # start-up; none may be left.
    OPEN=$(remote "sudo sqlite3 -readonly /var/lib/jellyfin/data/jellyfin.db \"SELECT group_concat(Username, ', ') FROM Users WHERE Password IS NULL OR Password = '';\"" || echo "?")
    if [[ -z "${OPEN}" ]]; then
        pass "every Jellyfin account has a password (none signs in with an empty one)"
    else
        fail "accounts without a password, open to an empty-password login: ${OPEN}"
    fi
fi

# ── Test 8: Published without the gate, hardened (ADR-032 D3) ─────────────────
header "Test 8: Published for Jellyfin's apps, hardened"
PUB="$(remote "jq -r 'select(.proxyPublished != false) | .proxyDomain // empty' /etc/nixos/jellyfin.json" || true)"
FW4="$(getent ahostsv4 firewall.mgmt.internal | awk '{print $1; exit}')"
if [[ -z "${PUB}" || -z "${FW4}" ]]; then
    skip "not published (no proxyDomain in /etc/nixos/jellyfin.json), or the firewall's address is unknown"
else
    via() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 --resolve "${PUB}:443:${FW4}" "https://${PUB}$1"; }
    INFO="$(via /System/Info/Public)"
    if [[ "${INFO}" == "200 " ]]; then
        pass "https://${PUB}/System/Info/Public answers without a sign-in — native apps can reach Jellyfin's login"
    else
        fail "https://${PUB}/System/Info/Public answered '${INFO}' (a 302 to Authentik means the gate is still on)"
    fi
    # The admin and diagnostic paths are open to home and netbird only; the
    # mothership is in mgmt, so it is refused like the internet is.
    for _p in /metrics /System/Logs /Startup/Configuration; do
        _c="$(via "${_p}")"
        [[ "${_c%% *}" == "403" ]] && pass "${_p} is closed outside the site's zones (403)" \
            || fail "${_p} answered '${_c}' outside the site's zones — expected 403"
    done
    GW4="$(remote "ip -4 route show default | awk '{print \$3; exit}'")"
    if [[ -n "${GW4}" ]] && remote "sudo grep -q '<string>${GW4}</string>' /var/lib/jellyfin/config/network.xml"; then
        pass "the firewall (${GW4}) is a known proxy: Jellyfin sees each client's own address"
    else
        fail "the firewall (${GW4:-unknown}) is not in network.xml KnownProxies"
    fi
    ADMIN_REMOTE="$(remote "k=\$(sudo cat /var/lib/jellyfin-tappaas/api-key 2>/dev/null); curl -s -H \"Authorization: MediaBrowser Token=\\\"\$k\\\"\" http://localhost:8096/Users | jq -r '.[] | select(.Name == \"admin\") | .Policy.EnableRemoteAccess'")"
    if [[ "${ADMIN_REMOTE}" == "false" ]]; then
        pass "admin signs in from the site only (no remote access)"
    else
        fail "admin's remote access is '${ADMIN_REMOTE:-unknown}' — jellyfin-tappaas-policy should have turned it off"
    fi
fi

# ── Test 7: Disk usage ────────────────────────────────────────────────────────
header "Test 7: Resource Usage"
MEM=$(remote "free -h | grep Mem" || true)
DISK=$(remote "df -h / | tail -1" || true)
inf "Memory : ${MEM}"
inf "OS disk: ${DISK}"
pass "Resource info retrieved"

# ── Summary ───────────────────────────────────────────────────────────────────
header "Test Summary"
log "  ${GN}Passed:${CL}  ${PASSED}"
log "  ${RD}Failed:${CL}  ${FAILED}"
log "  ${YW}Skipped:${CL} ${SKIPPED}"
log ""
log "Total: $((PASSED + FAILED + SKIPPED))"

if [[ "${FAILED}" -eq 0 ]]; then
    log "${GN}${BOLD}All tests passed!${CL}"
    EXIT_CODE=0
else
    log "${RD}${BOLD}Some tests failed — review output above.${CL}"
    EXIT_CODE=1
fi
log "Full log: ${LOG_FILE}"
exit "${EXIT_CODE}"
