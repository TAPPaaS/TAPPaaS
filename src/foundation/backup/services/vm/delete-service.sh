#!/usr/bin/env bash
#
# TAPPaaS Backup VM Service - Delete
#
# Removes a consuming module's VM from the shared TAPPaaS PBS backup job so the
# job does not reference a destroyed guest (vzdump errors on missing VMIDs).
# Deletes the job entirely if it becomes empty. Idempotent. See issue #200.
#
# Usage: delete-service.sh <module-name>
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
    info "backup:vm: ${MODULE} has no vmid — nothing to remove from backup"
    exit 0
fi

info "${BOLD}backup:vm: removing ${BL}${VMNAME}${CL} (VMID ${VMID}) from PBS backup${CL}"
pbs_remove_vmid "${VMID}"
info "  ${GN}✓${CL} backup:vm delete-service completed"
