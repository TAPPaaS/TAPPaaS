#!/usr/bin/env bash
#
# TAPPaaS Backup — push target onboarding (ADR-012 P4, #402/#389).
#
# WE push our VM backups to a REMOTE PBS (the mirror of Class B external-receive,
# seen from the sender). Registers the remote PBS as a Proxmox `pbs` storage
# `offsite-<name>`; the managed vzdump backup job then writes there. When this is
# the remote-only default (makeDefault=true, or --make-default), it also points
# the module's managed backup job at that storage by setting .pbsStorageName, so
# the existing pbs-job.sh machinery (alwaysBackup + dependsOn:backup:vm) pushes
# the opted-in VMs off-site.
#
# The credential we use is WRITE-NO-DELETE (granted remote-side) and the REMOTE
# owns prune/retention/immutability — the §3.5 append-only invariant.
#
# Invoked by `backup-manage.sh add-push <name>`. Reads config from
# ${CONFIG_DIR}/push-<name>.json; password + fingerprint are prompted, never stored.
#
# Usage: install-service.sh <name> [--make-default]
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
[[ -n "${NAME}" ]] || die "Usage: $0 <name> [--make-default]"
MAKE_DEFAULT_FLAG="${2:-}"

CFG="${CONFIG_DIR}/push-${NAME}.json"
[[ -f "${CFG}" ]] || die "push target config not found: ${CFG} (copy services/push/push.json there and edit)"

host="$(jq -r '.remoteHost // empty' "${CFG}")"
rstore="$(jq -r '.remoteStore // empty' "${CFG}")"
ns="$(jq -r '.namespace // empty' "${CFG}")"
port="$(jq -r '.remotePort // ""' "${CFG}")"
authid="$(jq -r '.authId // empty' "${CFG}")"
zone="$(jq -r '.zone0 // "mgmt"' "${CONFIG_DIR}/backup.json" 2>/dev/null || echo mgmt)"
make_default="$(jq -r 'if .makeDefault then "true" else "false" end' "${CFG}")"
[[ "${MAKE_DEFAULT_FLAG}" == "--make-default" ]] && make_default="true"

[[ -n "${host}" && -n "${rstore}" && -n "${authid}" ]] \
    || die "config ${CFG} must set remoteHost, remoteStore and authId"

debug "${BOLD}Onboarding push target '${NAME}' → ${host}:${rstore}/${ns} (we push, write-only)${CL}"

# Remote PBS credential — prompted, never persisted to the repo/config.
read -rsp "  Password for ${authid} on the remote PBS: " PW; echo
read -rp  "  Remote PBS TLS fingerprint (sha256, blank to skip): " FP
[[ -n "${PW}" ]] || die "password is required"

pbs_push_storage_ensure "${NAME}" "${host}" "${rstore}" "${ns}" "${authid}" "${PW}" "${FP}" "${port}" "${zone}"

sname="$(_pbs_push_storage_name "${NAME}")"
if [[ "${make_default}" == "true" ]]; then
    # Point the managed backup job at the off-site storage: set .pbsStorageName so
    # pbs-job.sh (pbs_ensure_always / backup:vm) creates/targets the job there.
    tmp="$(mktemp)"
    jq --arg s "${sname}" '.pbsStorageName = $s' "${CONFIG_DIR}/backup.json" >"${tmp}" && mv "${tmp}" "${CONFIG_DIR}/backup.json"
    info "  ${GN}✓${CL} managed backup job now targets ${BL}${sname}${CL} (remote-only default)"
    pbs_ensure_always || warn "  Could not register some alwaysBackup VMs into the push job"
else
    info "  ${GN}✓${CL} push storage ready as ${BL}${sname}${CL}; target a backup job at it, or set makeDefault to route the managed job off-site"
fi

debug "  ${GN}✓${CL} push target '${NAME}' onboarded"
