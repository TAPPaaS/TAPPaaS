#!/usr/bin/env bash
#
# TAPPaaS Backup — push target offboarding (ADR-012 P4).
#
# Removes the local `offsite-<name>` Proxmox storage. Does NOT touch the remote:
# we hold write-no-delete, and the off-site data + its retention belong to the
# remote (§3.5). If this was the remote-only default target, the managed backup
# job loses its destination — restore a local PBS (promote, P2) or wire another
# push target before relying on backups again.
#
# Invoked by `backup-manage.sh remove-push <name>`.
#
# Usage: delete-service.sh <name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-push.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-push.sh"

NAME="${1:-}"
[[ -n "${NAME}" ]] || die "Usage: $0 <name>"

zone="$(jq -r '.zone0 // "mgmt"' "${CONFIG_DIR}/backup.json" 2>/dev/null || echo mgmt)"
sname="$(_pbs_push_storage_name "${NAME}")"

# If the managed job currently targets this push storage, warn loudly.
cur_store="$(pbs_storage_name)"
if [[ "${cur_store}" == "${sname}" ]]; then
    warn "The managed backup job currently targets ${sname} — removing it leaves the job with no destination."
    warn "  Promote a local PBS (update-module.sh backup) or wire another push target first."
fi

pbs_push_storage_delete "${NAME}" "${zone}"
debug "  ${GN}✓${CL} push target '${NAME}' offboarded"
