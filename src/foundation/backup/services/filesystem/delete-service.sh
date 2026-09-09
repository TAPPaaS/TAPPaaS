#!/usr/bin/env bash
#
# backup:filesystem — delete-service (ADR-012 §3.1). Un-wires the capture and
# leaves the DATA alone.
#
# Removing a module must not destroy its backups: that is precisely when they
# are about to be needed. So this removes the manifest, the runner and the
# guest's write credential, and leaves the fs/<module> namespace, its snapshots
# and the escrowed encryption key in place. Reclaiming that space is a separate,
# deliberate act (PBS prune / namespace delete).
#
# Usage: delete-service.sh <module-name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"
# shellcheck source=../../lib/pbs-fs.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-fs.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

CONFIG="${CONFIG_DIR:-/home/tappaas/config}/${MODULE}.json"
VMNAME="$(jq -r '.vmname // empty' "${CONFIG}" 2>/dev/null || true)"
ZONE="$(jq -r '.zone0 // "mgmt"' "${CONFIG}" 2>/dev/null || echo mgmt)"

MANIFEST="$(pbs_fs_manifest_path "${MODULE}")"
[[ -f "${MANIFEST}" ]] && { rm -f "${MANIFEST}"; info "  removed capture manifest ${MANIFEST}"; }

if [[ -n "${VMNAME}" ]]; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${VMNAME}.${ZONE}.internal" \
        "rm -f /home/tappaas/config/${MODULE}.fsbackup.json; sudo rm -f /etc/secrets/backup-fs.pw" 2>/dev/null \
        && info "  removed the runner's manifest + write credential from ${VMNAME}" \
        || warn "  could not clean up on ${VMNAME} (it may already be gone) — harmless"
fi

info "  ${GN}✓${CL} backup:filesystem un-wired for ${MODULE}"
info "     Its file backups in $(pbs_fs_namespace "${MODULE}") and the escrowed key are KEPT — deleting a module"
info "     is exactly when its backups matter. Reclaim them deliberately if you mean to."
