#!/usr/bin/env bash
#
# backup:filesystem — update-service (ADR-012 §3.1). Re-asserts the capture:
# the namespace/ACL, the manifest (paths or schedule may have changed) and the
# deployed runner. Idempotent; the credential and key are left alone once they
# exist — rotating them is a deliberate act, not a side effect of an update.
#
# Usage: update-service.sh <module-name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"
# shellcheck source=../../lib/pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-placement.sh"
# shellcheck source=../../lib/pbs-fs.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-fs.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

if pbs_is_shim; then
    debug "backup:filesystem: backup is a shim — skipping capture re-assertion for ${MODULE}."
    exit 0
fi

CONFIG="${CONFIG_DIR:-/home/tappaas/config}/${MODULE}.json"
check_json "${CONFIG}" || exit 1

VMNAME="$(jq -r '.vmname // empty' "${CONFIG}")"
ZONE="$(jq -r '.zone0 // "mgmt"' "${CONFIG}")"
[[ -n "${VMNAME}" ]] || { warn "backup:filesystem: ${MODULE} has no vmname"; exit 0; }
GUEST="${VMNAME}.${ZONE}.internal"

mapfile -t FS_PATHS < <(pbs_fs_paths "${MODULE}")
if [[ "${#FS_PATHS[@]}" -eq 0 ]]; then
    warn "backup:filesystem: ${MODULE} declares no backup.filesystemPaths — nothing to capture"
    exit 0
fi

# The namespace + ACL are re-asserted without a password: the login exists by
# now, and pbs_fs_ensure_target only needs one when it has to create it.
pbs_fs_ensure_target "${MODULE}" || die "could not re-assert the PBS side for ${MODULE}"

SCHEDULE="$(pbs_schedule_resolve "${MODULE}")"
NS="$(pbs_fs_namespace "${MODULE}")"
REPO="$(pbs_fs_authid "${MODULE}")@$(pbs_pbs_url):$(pbs_storage_name)"
pbs_fs_write_manifest "${MODULE}" "${REPO}" "${NS}" "${SCHEDULE}" "$(pbs_fs_fingerprint)" "${FS_PATHS[@]}" \
    || die "could not update the capture manifest"

MANIFEST="$(pbs_fs_manifest_path "${MODULE}")"
# A failed delivery FAILS the step (#626). This used to warn and fall through to
# the success line, so a runner that had never reached the guest at all was
# reported as "re-applied" — and the warning's claim that "the previous ones
# stay in place" is not true on a first wiring, where there is no previous one.
pbs_fs_deploy_runner "${MODULE}" "${GUEST}" "${MANIFEST}" \
    || die "could not refresh the capture runner on ${GUEST} — backup:filesystem is NOT converged for ${MODULE}"

debug "  ${GN}✓${CL} backup:filesystem update-service completed for ${MODULE} (${SCHEDULE})"
