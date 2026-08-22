#!/usr/bin/env bash
#
# TAPPaaS Backup — push target re-assert (ADR-012 P4, #402/#389; #495).
#
# The converge half of the push-target pair. install-service.sh ONBOARDS a push
# target: it prompts for the remote PBS password and TLS fingerprint, then
# registers the `offsite-<name>` Proxmox storage. Neither credential is ever
# persisted (by design — §3.5), so onboarding cannot be replayed unattended.
#
# This script therefore re-asserts only what is derivable from
# ${CONFIG_DIR}/push-<name>.json and the live cluster:
#   - the offsite-<name> storage still exists (missing => operator action, since
#     re-creating it needs the password we deliberately do not store)
#   - when makeDefault is set, the managed backup job still targets that storage
#     (.pbsStorageName in backup.json) and the alwaysBackup VMs are registered
#
# It exists so reconcile has no reason to fall back to install-service.sh, which
# would block on a password prompt inside an unattended converge (#495).
#
# Usage: update-service.sh <name>
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

CFG="${CONFIG_DIR}/push-${NAME}.json"
[[ -f "${CFG}" ]] || die "push target config not found: ${CFG} (onboard it first: backup-manage.sh add-push ${NAME})"

zone="$(jq -r '.zone0 // "mgmt"' "${CONFIG_DIR}/backup.json" 2>/dev/null || echo mgmt)"
make_default="$(jq -r 'if .makeDefault then "true" else "false" end' "${CFG}")"
sname="$(_pbs_push_storage_name "${NAME}")"

debug "${BOLD}Re-asserting push target '${NAME}' (${sname})${CL}"

if ! _pbs_pvesm_has "${sname}" "${zone}"; then
    # Recreating the storage needs the remote password, which is never stored.
    die "push storage ${sname} is missing — re-onboard it with 'backup-manage.sh add-push ${NAME}' (the remote credential is not persisted, so it cannot be re-created unattended)"
fi
info "  ${GN}✓${CL} push storage ${BL}${sname}${CL} present"

if [[ "${make_default}" == "true" ]]; then
    current="$(jq -r '.pbsStorageName // empty' "${CONFIG_DIR}/backup.json" 2>/dev/null || true)"
    if [[ "${current}" != "${sname}" ]]; then
        tmp="$(mktemp)"
        jq --arg s "${sname}" '.pbsStorageName = $s' "${CONFIG_DIR}/backup.json" >"${tmp}" && mv "${tmp}" "${CONFIG_DIR}/backup.json"
        info "  ${GN}✓${CL} managed backup job re-pointed at ${BL}${sname}${CL} (was '${current:-unset}')"
    else
        debug "  managed backup job already targets ${sname}"
    fi
    pbs_ensure_always || warn "  Could not register some alwaysBackup VMs into the push job"
fi

debug "  ${GN}✓${CL} push target '${NAME}' re-asserted"
