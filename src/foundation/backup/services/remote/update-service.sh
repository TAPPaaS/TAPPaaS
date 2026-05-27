#!/usr/bin/env bash
#
# TAPPaaS Backup — Class A (TAPPaaS buddy) update (issue #227).
#
# Re-applies the buddy's namespace, sync-job schedule/remove-vanished and the
# namespace-scoped prune-job from ${CONFIG_DIR}/remote-<name>.json. Does NOT
# touch the stored remote credentials (re-run add-remote to rotate those).
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

CFG="${CONFIG_DIR}/remote-${NAME}.json"
[[ -f "${CFG}" ]] || die "buddy config not found: ${CFG}"

store="$(pbs_storage_name)"
ns="$(jq -r '.namespace // empty' "${CFG}")"
sched="$(jq -r '.pullSchedule // "04:00"' "${CFG}")"
rv="$(jq -r 'if .removeVanished then "true" else "false" end' "${CFG}")"
retention="$(jq -c '.retention // {}' "${CFG}")"
[[ -n "${ns}" ]] || die "config ${CFG} must set namespace"

info "${BOLD}Updating TAPPaaS buddy '${NAME}' (${store}/${ns})${CL}"
pbs_ns_ensure "${ns}"

if _pbs_syncjob_exists "sync-${NAME}"; then
    pbs_syncjob_ensure "sync-${NAME}" "${store}" "${ns}" "${NAME}" "" "" "${sched}" "${rv}"
    info "  ${GN}✓${CL} sync-job sync-${NAME} schedule=${sched} remove-vanished=${rv}"
else
    warn "  sync-job sync-${NAME} missing — run 'backup-manage.sh add-remote ${NAME}' to (re)create it with credentials"
fi

read -ra ret <<< "$(_pbs_retention_args "${retention}")"
[[ ${#ret[@]} -gt 0 ]] && pbs_prunejob_ensure_ns "prune-remote-${NAME}" "${store}" "${ns}" "02:30" "${ret[@]}"

info "  ${GN}✓${CL} buddy '${NAME}' update completed"
