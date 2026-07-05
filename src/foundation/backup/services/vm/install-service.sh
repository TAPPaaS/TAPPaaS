#!/usr/bin/env bash
#
# TAPPaaS Backup VM Service - Install
#
# Registers a consuming module's VM in the shared TAPPaaS PBS backup job, so
# that modules declaring "dependsOn": ["backup:vm"] are actually backed up.
# Idempotent. See issue #200.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-placement.sh"

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 1
fi

# Shim backup (no PBS datastore, ADR-012): dependsOn:backup:vm is satisfied so the
# consumer installs, but there is no job to register into yet. Degrade gracefully
# — the VM is picked up automatically once the shim is promoted (update.sh re-runs
# the reconcile). Surface it rather than failing the dependent's install.
if pbs_is_shim; then
    warn "backup:vm: backup is a shim (no PBS datastore) — skipping backup registration for ${MODULE}."
    warn "  It will be backed up once backup is promoted: update-module.sh backup"
    exit 0
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 1

VMID="$(get_config_value 'vmid')"
VMNAME="$(get_config_value 'vmname' "${MODULE}")"

if [[ -z "${VMID}" ]]; then
    warn "backup:vm: ${MODULE} has no vmid — nothing to register for backup"
    exit 0
fi

debug "${BOLD}backup:vm: registering ${BL}${VMNAME}${CL} (VMID ${VMID}) for PBS backup${CL}"
pbs_ensure_vmid "${VMID}"
debug "  ${GN}✓${CL} backup:vm install-service completed"
