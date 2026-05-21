#!/usr/bin/env bash
#
# TAPPaaS Backup VM Service - Update
#
# Re-asserts the consuming module's VM membership in the shared TAPPaaS PBS
# backup job (e.g. after a vmid change) and migrates a legacy --all job to the
# managed model. Idempotent. See issue #200.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 1
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 1

VMID="$(get_config_value 'vmid')"
VMNAME="$(get_config_value 'vmname' "${MODULE}")"

if [[ -z "${VMID}" ]]; then
    warn "backup:vm: ${MODULE} has no vmid — nothing to register for backup"
    exit 0
fi

info "${BOLD}backup:vm: ensuring ${BL}${VMNAME}${CL} (VMID ${VMID}) is covered by PBS backup${CL}"
pbs_ensure_vmid "${VMID}"
info "  ${GN}✓${CL} backup:vm update-service completed"
