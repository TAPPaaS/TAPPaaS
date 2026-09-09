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
    debug "backup:vm: ${MODULE} has no vmid — nothing to remove from backup"
    exit 0
fi

debug "${BOLD}backup:vm: removing ${BL}${VMNAME}${CL} (VMID ${VMID}) from PBS backup${CL}"
# Remove from every bucket: the guest is in exactly one, but which one depends
# on a schedule that may have changed since it was placed (ADR-012 §3.2).
while IFS= read -r _bucket; do
    pbs_remove_vmid "${VMID}" "${_bucket}" quiet
done < <(pbs_buckets)
debug "  ${GN}✓${CL} backup:vm delete-service completed"
