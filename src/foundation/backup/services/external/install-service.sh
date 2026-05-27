#!/usr/bin/env bash
#
# TAPPaaS Backup — Class B (external client) onboarding (issue #227).
#
# Push model: a third-party client (Synology, TrueNAS Scale, MacBook, ...)
# writes into an isolated namespace `external/<name>`. The client authenticates
# as `<name>@pbs` and is granted the DatastoreBackup role on that namespace ONLY
# — write, no delete, no visibility into other namespaces. An admin-owned
# prune-job controls retention so a compromised client cannot erase history.
# Datastore-wide verify-new (issue #228) flags encryption-key swaps. Client-side
# encryption is the client's responsibility (the operator cannot read the data).
#
# Invoked by `backup-manage.sh add-external <name>`. Reads the client config
# from ${CONFIG_DIR}/external-<name>.json.
#
# Usage: install-service.sh <name>
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
[[ -f "${CFG}" ]] || die "external client config not found: ${CFG} (copy services/external/external.json there and edit)"

store="$(pbs_storage_name)"
ns="$(jq -r '.namespace // empty' "${CFG}")"
[[ -n "${ns}" ]] || ns="external/${NAME}"
retention="$(jq -c '.retention // {}' "${CFG}")"
userid="${NAME}@pbs"

info "${BOLD}Onboarding external client '${NAME}' → ${store}/${ns} (push, write-only)${CL}"

# Client password — prompted (blank auto-generates and is shown once).
read -rsp "  Password for ${userid} (blank to auto-generate): " PW; echo
if [[ -z "${PW}" ]]; then
    PW="$(openssl rand -base64 18)"
    GENERATED=1
fi

pbs_ns_ensure "${ns}"
if _pbs_user_exists "${userid}"; then
    info "  user ${userid} already exists (password unchanged)"
else
    pbs_user_ensure "${userid}" "${PW}"
    info "  ${GN}✓${CL} created user ${userid}"
fi

# Write-only ACL scoped to this namespace only (no delete, no other namespaces).
pbs_acl_ensure "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreBackup "${userid}"
info "  ${GN}✓${CL} ${userid} granted DatastoreBackup on ${ns} (write, no delete)"

# Admin-owned namespace prune-job (the client cannot prune).
read -ra ret <<< "$(_pbs_retention_args "${retention}")"
if [[ ${#ret[@]} -gt 0 ]]; then
    pbs_prunejob_ensure_ns "prune-external-${NAME}" "${store}" "${ns}" "02:45" "${ret[@]}"
    info "  ${GN}✓${CL} admin prune-job prune-external-${NAME} scoped to ${ns}"
fi

echo
info "${BOLD}Client setup (run on the client; encrypt with the CLIENT's own key):${CL}"
echo "  Repository : ${userid}@<pbs-reachable-host>:${store}"
echo "  Namespace  : ${ns}"
echo "  Example    : proxmox-backup-client backup data.pxar:/path \\"
echo "                 --repository '${userid}@<pbs-host>:${store}' --ns '${ns}' \\"
echo "                 --keyfile /path/to/client.key   # client-side encryption"
echo "  Fingerprint: proxmox-backup-manager cert info | grep Fingerprint   (on the PBS node)"
if [[ "${GENERATED:-0}" == "1" ]]; then
    warn "  Generated password for ${userid} (store it now, shown only once): ${PW}"
fi
info "  ${GN}✓${CL} external client '${NAME}' onboarded"
