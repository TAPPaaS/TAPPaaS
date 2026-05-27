#!/usr/bin/env bash
#
# TAPPaaS Backup — Class B (external client) update (issue #227).
#
# Re-applies the client's namespace, write-only ACL and admin prune-job from
# ${CONFIG_DIR}/external-<name>.json. Never resets the client's password.
# Idempotent.
#
# Usage: update-service.sh <name>
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
[[ -n "${NAME}" ]] || die "Usage: $0 <name>"

CFG="${CONFIG_DIR}/external-${NAME}.json"
[[ -f "${CFG}" ]] || die "external client config not found: ${CFG}"

store="$(pbs_storage_name)"
ns="$(jq -r '.namespace // empty' "${CFG}")"
[[ -n "${ns}" ]] || ns="external/${NAME}"
retention="$(jq -c '.retention // {}' "${CFG}")"
userid="${NAME}@pbs"

info "${BOLD}Updating external client '${NAME}' (${store}/${ns})${CL}"
pbs_ns_ensure "${ns}"

if _pbs_user_exists "${userid}"; then
    pbs_acl_ensure "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreBackup "${userid}"
    info "  ${GN}✓${CL} ACL re-applied for ${userid}"
else
    warn "  user ${userid} missing — run 'backup-manage.sh add-external ${NAME}' to (re)create it"
fi

read -ra ret <<< "$(_pbs_retention_args "${retention}")"
[[ ${#ret[@]} -gt 0 ]] && pbs_prunejob_ensure_ns "prune-external-${NAME}" "${store}" "${ns}" "02:45" "${ret[@]}"

info "  ${GN}✓${CL} external client '${NAME}' update completed"
