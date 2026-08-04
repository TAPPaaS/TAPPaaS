#!/usr/bin/env bash
#
# TAPPaaS Cluster Storage Service - Delete (dispatcher)
#
# Empties the module's own .nix marker block (so a deleted module leaves no
# stale fileSystems entry behind) and best-effort unmounts on the live VM if
# still reachable. Never touches the share/backend itself — the share is
# foundation-owned and may have other consumers; only nfs-manager.sh remove
# (an explicit admin action) removes a share.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: $0 <module-name>"
    exit 1
fi

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${MODULE_JSON}" ]] || { debug "  ${MODULE_JSON} already gone — nothing to clean up"; exit 0; }
check_json "${MODULE_JSON}" || exit 2

ENTRY_COUNT=$(jq '(.sharedStorage // []) | length' <<<"${JSON}")
if [[ "${ENTRY_COUNT}" -eq 0 ]]; then
    debug "  No 'sharedStorage' entries declared for ${MODULE} — nothing to do"
    exit 0
fi

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
NODE_FQDN="${VMNAME}.${ZONE0}.internal"

MODULE_DIR="$(get_module_dir "${MODULE}" 2>/dev/null || true)"
if [[ -n "${MODULE_DIR}" ]]; then
    NIX_FILE="${MODULE_DIR}/${VMNAME}.nix"
    if [[ -f "${NIX_FILE}" ]] && grep -q '# BEGIN cluster:storage' "${NIX_FILE}"; then
        # shellcheck source=storage-common.sh disable=SC1091
        . "${SCRIPT_DIR}/storage-common.sh"
        storage_rewrite_nix_block "${NIX_FILE}" ""
        debug "  cluster:storage marker block emptied in ${NIX_FILE}"
    fi
fi

# Best-effort: unmount on the live VM if it's still reachable (module's own
# VM is usually already being deleted around this point, so failures here
# are expected and non-fatal).
while IFS= read -r mount_point; do
    [[ -z "${mount_point}" ]] && continue
    ssh -n -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
        "tappaas@${NODE_FQDN}" "sudo umount '${mount_point}'" 2>/dev/null || true
done < <(jq -r '(.sharedStorage // [])[].mountPoint' <<<"${JSON}")

info "  ${GN}✓${CL} cluster:storage delete-service completed"
