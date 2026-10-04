#!/usr/bin/env bash
#
# pvehost:nfs — delete-service (ADR-029 D6, #766). Takes the consumer's mounts
# away and leaves every share's DATA alone: the export belongs to its node, not
# to the consumer. Its grants stay too — they are the node's declaration, and
# with the consumer gone they simply resolve to nobody on the next reconcile.
#
# Usage: delete-service.sh <consumer>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=nfs-service.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-service.sh"

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { echo "Usage: $0 <consumer>"; exit 1; }
nfs_is_instance "${CONSUMER}" || { info "pvehost:nfs: no config/${CONSUMER}.json — nothing to remove"; exit 0; }

target="$(nfs_consumer_target "${CONSUMER}")" || { info "pvehost:nfs: ${CONSUMER} has no guest — nothing to remove"; exit 0; }
case "$(nfs_consumer_os "${CONSUMER}")" in
    nixos)
        tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo rm -f ${NFS_GUEST_FRAGMENT}" 2>/dev/null \
            && info "  ${CONSUMER}: ${NFS_GUEST_FRAGMENT} removed — its mounts go with the next rebuild; share data kept" \
            || warn "  ${CONSUMER}: could not reach the guest to remove ${NFS_GUEST_FRAGMENT} (it is likely gone already)" ;;
    debian)
        tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo bash -s" 2>/dev/null <<SH \
            && info "  ${CONSUMER}: NFS mounts removed from /etc/fstab and unmounted; share data kept" \
            || warn "  ${CONSUMER}: could not reach the guest to remove its NFS mounts (it is likely gone already)"
awk '\$3 == "nfs" && f {print \$2} \$0 == "${NFS_FSTAB_BEGIN}" {f = 1} \$0 == "${NFS_FSTAB_END}" {f = 0}' /etc/fstab | xargs -r -n1 umount -l 2>/dev/null || true
awk -v b='${NFS_FSTAB_BEGIN}' -v e='${NFS_FSTAB_END}' '\$0 == b {s = 1; next} \$0 == e {s = 0; next} !s' /etc/fstab > /etc/fstab.tappaas-nfs && mv /etc/fstab.tappaas-nfs /etc/fstab
systemctl daemon-reload
SH
        ;;
esac
exit 0
