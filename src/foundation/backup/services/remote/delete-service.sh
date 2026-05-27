#!/usr/bin/env bash
#
# TAPPaaS Backup — Class A (TAPPaaS buddy) offboarding (issue #227).
#
# Removes the sync-job, prune-job, PBS remote entry and any read ACL for a
# buddy. The synced namespace data is KEPT by default (so an offsite copy
# survives offboarding); pass --purge to also delete the namespace and its
# backup groups.
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
CFG="${CONFIG_DIR}/remote-${NAME}.json"
ns="$(jq -r '.namespace // empty' "${CFG}" 2>/dev/null || true)"
[[ -n "${ns}" ]] || ns="remote/${NAME}"
readauth="$(jq -r '.readAuthId // ""' "${CFG}" 2>/dev/null || true)"

info "${BOLD}Offboarding TAPPaaS buddy '${NAME}'${CL}"
pbs_syncjob_delete "sync-${NAME}"   && info "  removed sync-job sync-${NAME}"
pbs_prunejob_delete "prune-remote-${NAME}" && info "  removed prune-job prune-remote-${NAME}"
pbs_remote_delete "${NAME}"         && info "  removed remote ${NAME}"
[[ -n "${readauth}" ]] && pbs_acl_delete "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreReader "${readauth}"

if [[ "${PURGE}" == "--purge" ]]; then
    warn "  --purge: deleting namespace ${ns} and all its backups"
    pbs_ns_delete "${ns}" --purge && info "  deleted namespace ${ns}"
else
    info "  namespace ${ns} kept (offsite copy preserved) — re-run with --purge to delete its data"
fi

info "  ${GN}✓${CL} buddy '${NAME}' offboarded"
