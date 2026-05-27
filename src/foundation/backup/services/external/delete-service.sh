#!/usr/bin/env bash
#
# TAPPaaS Backup — Class B (external client) offboarding (issue #227).
#
# Removes the client's write ACL, PBS user and admin prune-job. The client's
# namespace data is KEPT by default; pass --purge to also delete the namespace
# and its backup groups.
#
# Usage: delete-service.sh <name> [--purge]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"

NAME="${1:-}"
PURGE="${2:-}"
[[ -n "${NAME}" ]] || die "Usage: $0 <name> [--purge]"

store="$(pbs_storage_name)"
CFG="${CONFIG_DIR}/external-${NAME}.json"
ns="$(jq -r '.namespace // empty' "${CFG}" 2>/dev/null || true)"
[[ -n "${ns}" ]] || ns="external/${NAME}"
userid="${NAME}@pbs"

info "${BOLD}Offboarding external client '${NAME}'${CL}"
pbs_prunejob_delete "prune-external-${NAME}" && info "  removed prune-job prune-external-${NAME}"
pbs_acl_delete "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreBackup "${userid}" && info "  removed ACL for ${userid}"
pbs_user_delete "${userid}" && info "  removed user ${userid}"

if [[ "${PURGE}" == "--purge" ]]; then
    warn "  --purge: deleting namespace ${ns} and all its backups"
    pbs_ns_delete "${ns}" --purge && info "  deleted namespace ${ns}"
else
    info "  namespace ${ns} kept — re-run with --purge to delete its data"
fi

info "  ${GN}✓${CL} external client '${NAME}' offboarded"
