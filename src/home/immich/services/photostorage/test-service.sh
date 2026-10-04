#!/usr/bin/env bash
# TAPPaaS Module: immich — photostorage service test
#
# Verifies the data disk and Immich API on the Immich VM.
# Run from tappaas-cicd after services/photostorage/install-service.sh.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' 'immich')"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'allocate')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0

pass() { echo -e "${GN}[PASS]${CL} $1"; ((PASSED++)); }
fail() { echo -e "${RD}[FAIL]${CL} $1"; ((FAILED++)); }

echo ""
echo -e "${BOLD}immich: photostorage service test${CL}"
echo "  Target: tappaas@${IMMICH_HOST}"

remote() { ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" "$1" 2>/dev/null; }

# Test 1: /var/lib/immich mounted
MOUNT=$(remote "mountpoint -q /var/lib/immich && echo yes || echo no")
[[ "${MOUNT}" == "yes" ]] && pass "/var/lib/immich is mounted" || fail "/var/lib/immich is not mounted"

# Test 2: storage backend matches the declared mediaStorage mode
if [[ "${MEDIA_MODE}" == "share" ]]; then
    FSTYPE=$(remote "stat -f -c %T /var/lib/immich 2>/dev/null || echo unknown")
    [[ "${FSTYPE}" == "nfs" || "${FSTYPE}" == "smb2" || "${FSTYPE}" == "cifs" ]] \
      && pass "/var/lib/immich is a network share (${FSTYPE})" \
      || fail "/var/lib/immich is not a network share (got: ${FSTYPE})"
else
    LABEL=$(remote "sudo blkid -s LABEL -o value /dev/disk/by-label/immich-data 2>/dev/null || echo none")
    [[ "${LABEL}" == "immich-data" ]] && pass "Disk label 'immich-data' found" || fail "Label 'immich-data' not found (got: ${LABEL})"
fi

# Test 3: Immich service active
IM_STATUS=$(remote "systemctl is-active immich-server 2>/dev/null || echo inactive")
[[ "${IM_STATUS}" == "active" ]] && pass "immich-server service is active" || fail "immich-server service is ${IM_STATUS}"

# Test 4: API reachable
PING=$(remote "curl -s --max-time 10 http://localhost:2283/api/server/ping 2>/dev/null || echo unreachable")
[[ "${PING}" == *pong* ]] && pass "Immich API responded (ping → pong)" || fail "Immich API did not answer ping (got: ${PING})"

echo ""
echo -e "  ${GN}Passed:${CL} ${PASSED}  ${RD}Failed:${CL} ${FAILED}"
[[ "${FAILED}" -eq 0 ]] && exit 0 || exit 1
