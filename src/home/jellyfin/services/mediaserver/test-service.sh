#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — mediaserver service test
#
# Verifies the media disk and Jellyfin API on the Jellyfin VM.
# Run from tappaas-cicd after services/mediaserver/install-service.sh.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' 'jellyfin')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'allocate')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0

pass() { echo -e "${GN}[PASS]${CL} $1"; ((PASSED++)); }
fail() { echo -e "${RD}[FAIL]${CL} $1"; ((FAILED++)); }

echo ""
echo -e "${BOLD}jellyfin: mediaserver service test${CL}"
echo "  Target: tappaas@${JELLYFIN_HOST}"

remote() { ssh ${SSH_OPTS} "tappaas@${JELLYFIN_HOST}" "$1" 2>/dev/null; }

# Test 1: /media mounted
MOUNT=$(remote "mountpoint -q /media && echo yes || echo no")
[[ "${MOUNT}" == "yes" ]] && pass "/media is mounted" || fail "/media is not mounted"

# Test 2: media backend matches the declared mediaStorage mode
if [[ "${MEDIA_MODE}" == "share" ]]; then
    FSTYPE=$(remote "stat -f -c %T /media 2>/dev/null || echo unknown")
    [[ "${FSTYPE}" == "nfs" || "${FSTYPE}" == "smb2" || "${FSTYPE}" == "cifs" ]] \
      && pass "/media is a network share (${FSTYPE})" \
      || fail "/media is not a network share (got: ${FSTYPE})"
else
    LABEL=$(remote "sudo blkid -s LABEL -o value /dev/disk/by-label/jellyfin-media 2>/dev/null || echo none")
    [[ "${LABEL}" == "jellyfin-media" ]] && pass "Disk label 'jellyfin-media' found" || fail "Label 'jellyfin-media' not found (got: ${LABEL})"
fi

# Test 3: Jellyfin service active
JF_STATUS=$(remote "systemctl is-active jellyfin 2>/dev/null || echo inactive")
[[ "${JF_STATUS}" == "active" ]] && pass "jellyfin service is active" || fail "jellyfin service is ${JF_STATUS}"

# Test 4: API reachable
HTTP_CODE=$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8096/health 2>/dev/null || echo 000")
[[ "${HTTP_CODE}" =~ ^(200|301|302)$ ]] && pass "Jellyfin API responded (HTTP ${HTTP_CODE})" || fail "Jellyfin API returned HTTP ${HTTP_CODE}"

echo ""
echo -e "  ${GN}Passed:${CL} ${PASSED}  ${RD}Failed:${CL} ${FAILED}"
[[ "${FAILED}" -eq 0 ]] && exit 0 || exit 1
