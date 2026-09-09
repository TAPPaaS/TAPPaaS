#!/usr/bin/env bash
#
# Revoke a REMOTE's pull access (ADR-012 §1.4).
#
# Removes the read-only grant, and the login if we created it. Their copy of
# our data is THEIRS and on THEIR datastore — we cannot reach it and this does
# not try to: revoking access stops future pulls, it does not unmake the copies
# already taken. That is inherent to off-site backup, not an oversight.
#
# Usage: offboard.sh <name> [--purge]     (--purge also removes the login)
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

CFG="${CONFIG_DIR:-/home/tappaas/config}/remote-${NAME}.json"
[[ -f "${CFG}" ]] || die "remote config not found: ${CFG}"

store="$(pbs_storage_name)"
authid="$(jq -r '.authId // empty' "${CFG}")"
ns="$(jq -r '.namespace // empty' "${CFG}")"
[[ -n "${authid}" ]] || die "remote-${NAME}.json has no authId"

acl_path="$(_pbs_ns_acl_path "${store}" "${ns}")"
pbs_acl_delete "${acl_path}" DatastoreReader "${authid}"
info "  ${GN}✓${CL} revoked ${authid}'s read access to ${acl_path}"

if [[ "${PURGE}" == "--purge" ]]; then
    if [[ "${authid}" == *"@pbs" ]] && _pbs_user_exists "${authid}"; then
        _pbs_node_run proxmox-backup-manager user remove "${authid}" \
            && info "  ${GN}✓${CL} removed login ${authid}"
    fi
fi

warn "  Copies they already pulled remain on THEIR datastore — out of our reach by design."
