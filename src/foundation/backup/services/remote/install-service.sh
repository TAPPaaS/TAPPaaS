#!/usr/bin/env bash
#
# TAPPaaS Backup — Class A (TAPPaaS buddy) onboarding (issue #227).
#
# Pull model: this PBS pulls another TAPPaaS cluster's PBS into an isolated
# namespace `remote/<name>`, with `--remove-vanished false` so a compromise at
# the source cannot erase our offsite copy. Encryption is preserved end-to-end
# (chunks arrive already encrypted at the source). The sync-job + prune-job are
# admin-owned; the buddy never gets delete rights here.
#
# Invoked by `backup-manage.sh add-remote <name>`. Reads the buddy config from
# ${CONFIG_DIR}/remote-<name>.json; API credentials are prompted, never stored.
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

CFG="${CONFIG_DIR}/remote-${NAME}.json"
[[ -f "${CFG}" ]] || die "buddy config not found: ${CFG} (copy services/remote/remote.json there and edit)"

store="$(pbs_storage_name)"
ns="$(jq -r '.namespace // empty' "${CFG}")"
rhost="$(jq -r '.remoteHost // empty' "${CFG}")"
rstore="$(jq -r '.remoteStore // empty' "${CFG}")"
rns="$(jq -r '.remoteNamespace // ""' "${CFG}")"
sched="$(jq -r '.pullSchedule // "04:00"' "${CFG}")"
rv="$(jq -r 'if .removeVanished then "true" else "false" end' "${CFG}")"
readauth="$(jq -r '.readAuthId // ""' "${CFG}")"
retention="$(jq -c '.retention // {}' "${CFG}")"

[[ -n "${ns}" && -n "${rhost}" && -n "${rstore}" ]] \
    || die "config ${CFG} must set namespace, remoteHost and remoteStore"

info "${BOLD}Onboarding TAPPaaS buddy '${NAME}' → ${store}/${ns} (pull from ${rhost})${CL}"

# Buddy PBS API credentials — prompted, never persisted to the repo/config.
read -rp "  Buddy PBS API auth-id (e.g. sync@pbs!token): " AUTHID
read -rsp "  Buddy PBS API password/secret: " PASSWORD; echo
read -rp "  Buddy PBS TLS fingerprint (sha256, blank to skip): " FP
[[ -n "${AUTHID}" && -n "${PASSWORD}" ]] || die "auth-id and password are required"

pbs_ns_ensure "${ns}"
pbs_remote_ensure "${NAME}" "${rhost}" "${AUTHID}" "${PASSWORD}" "${FP}"
pbs_syncjob_ensure "sync-${NAME}" "${store}" "${ns}" "${NAME}" "${rstore}" "${rns}" "${sched}" "${rv}"

# Namespace-scoped, admin-owned prune-job (the buddy cannot prune our copy).
read -ra ret <<< "$(_pbs_retention_args "${retention}")"
if [[ ${#ret[@]} -gt 0 ]]; then
    pbs_prunejob_ensure_ns "prune-remote-${NAME}" "${store}" "${ns}" "02:30" "${ret[@]}"
    info "  ${GN}✓${CL} prune-job prune-remote-${NAME} scoped to ${ns}"
fi

# Optional: grant the buddy read-only access to their own offsite copy.
if [[ -n "${readauth}" ]]; then
    pbs_acl_ensure "$(_pbs_ns_acl_path "${store}" "${ns}")" DatastoreReader "${readauth}"
    info "  ${GN}✓${CL} ${readauth} granted DatastoreReader on ${ns}"
fi

info "  ${GN}✓${CL} buddy '${NAME}' onboarded — sync-job sync-${NAME} pulls at ${sched} (remove-vanished=${rv})"
