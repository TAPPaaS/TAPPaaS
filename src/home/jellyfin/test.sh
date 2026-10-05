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

# ── Test 6: Disk usage ────────────────────────────────────────────────────────
header "Test 6: Resource Usage"
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
