#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — storage service test
#
# Verifies the NFS mount on the dependent (consumer) VM.
# Run from tappaas-cicd after services/storage/install-service.sh.
#
# Usage: MODULE_VMNAME=fileservice ./services/storage/test-service.sh

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

JELLYFIN_VMNAME="$(get_config_value 'vmname' 'jellyfin')"
JELLYFIN_ZONE="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_NFS_HOST="${JELLYFIN_VMNAME}.${JELLYFIN_ZONE}.internal"

CONSUMER_VMNAME="${MODULE_VMNAME:-}"
CONSUMER_ZONE="${MODULE_ZONE:-srvHome}"
CONSUMER_HOST="${CONSUMER_VMNAME}.${CONSUMER_ZONE}.internal"

if [[ -z "${CONSUMER_VMNAME}" ]]; then
    warn "MODULE_VMNAME is not set. Set it to the name of the consuming VM."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0

pass() { echo -e "${GN}[PASS]${CL} $1"; ((PASSED++)); }
fail() { echo -e "${RD}[FAIL]${CL} $1"; ((FAILED++)); }

echo ""
echo -e "${BOLD}jellyfin: storage service test${CL}"
echo "  Consumer: tappaas@${CONSUMER_HOST}"
echo "  Provider: ${JELLYFIN_NFS_HOST}:/media"

remote() { ssh ${SSH_OPTS} "tappaas@${CONSUMER_HOST}" "$1" 2>/dev/null; }

# Test 1: /media-jellyfin mounted
MOUNT=$(remote "mountpoint -q /media-jellyfin && echo yes || echo no")
[[ "${MOUNT}" == "yes" ]] && pass "/media-jellyfin is mounted on ${CONSUMER_VMNAME}" || fail "/media-jellyfin is not mounted"

# Test 2: fstab entry exists
FSTAB=$(remote "grep -c 'media-jellyfin' /etc/fstab 2>/dev/null || echo 0")
[[ "${FSTAB}" -ge 1 ]] && pass "fstab entry present" || fail "fstab entry missing — mount will not survive reboot"

# Test 3: downloads/complete is writable
WRITE=$(remote "test -w /media-jellyfin/downloads/complete && echo yes || echo no")
[[ "${WRITE}" == "yes" ]] && pass "/media-jellyfin/downloads/complete is writable" || fail "/media-jellyfin/downloads/complete is not writable"

# Test 4: Verify NFS source is Jellyfin VM
NFS_SRC=$(remote "df -h /media-jellyfin 2>/dev/null | tail -1" || echo "")
echo "    Mount info: ${NFS_SRC}"
[[ "${NFS_SRC}" == *"${JELLYFIN_NFS_HOST}"* ]] && pass "Mount source is ${JELLYFIN_NFS_HOST}" || fail "Unexpected mount source: ${NFS_SRC}"

echo ""
echo -e "  ${GN}Passed:${CL} ${PASSED}  ${RD}Failed:${CL} ${FAILED}"
[[ "${FAILED}" -eq 0 ]] && exit 0 || exit 1
