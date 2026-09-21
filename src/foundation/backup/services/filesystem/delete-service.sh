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

if TARGET="$(pbs_fs_target "${MODULE}")"; then
    # The runner itself goes too — the header has always said so, but it was
    # left behind, so an un-wired module kept an executable whose timer would
    # fire against a manifest that no longer exists (#626). A guest's systemd
    # trigger is declarative and shared; it goes inert on its own once the
    # runner is gone (ConditionPathExists). A machine's units were installed by
    # this service (#662), so this is what takes them away again.
    _host="${TARGET#*@}"
    _sudo="$(pbs_fs_sudo "${MODULE}")"
    _clean="rm -f '$(pbs_fs_manifest_dir_for "${MODULE}")/${MODULE}.fsbackup.json' '$(pbs_fs_runner_for "${MODULE}")'; ${_sudo}rm -f /etc/secrets/backup-fs.pw"
    if [[ "$(pbs_fs_kind "${MODULE}")" == "machine" ]]; then
        _clean+="; systemctl disable --now tappaas-fs-backup.timer 2>/dev/null; rm -f /etc/systemd/system/tappaas-fs-backup.{service,timer}; systemctl daemon-reload"
    fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${TARGET}" "${_clean}" 2>/dev/null \
        && info "  removed the runner, its manifest + write credential from ${_host}" \
        || warn "  could not clean up on ${_host} (it may already be gone) — harmless"
fi

info "  ${GN}✓${CL} backup:filesystem un-wired for ${MODULE}"
info "     Its file backups in $(pbs_fs_namespace "${MODULE}") and the escrowed key are KEPT — deleting a module"
info "     is exactly when its backups matter. Reclaim them deliberately if you mean to."
