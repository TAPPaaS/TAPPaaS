#!/usr/bin/env bash
#
# pvehost:nfs — install-service (ADR-029, #766). Gives a consumer the NFS shares
# its config."pvehost:nfs".mounts[] names:
#
#   1. every mount passes its shape check and the two-key check (D3, D11) — a
#      share the node does not declare, or does not grant, is refused here
#   2. each managed node a mount names converges its exports (D11): a declared
#      export not built yet is built now, and this consumer joins the client list
#   3. the mounts are written into the guest (D10): the NixOS fragment, applied by
#      the rebuild that install/update run after the services, or Debian's fstab
#
# Never creates an export and never touches share data. Idempotent.
#
# Usage: install-service.sh <consumer>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=nfs-service.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-service.sh"

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { echo "Usage: $0 <consumer>"; exit 1; }
nfs_is_instance "${CONSUMER}" || die "pvehost:nfs: no config/${CONSUMER}.json"

count="$(nfs_mounts "${CONSUMER}" | grep -c . || true)"
info "${BOLD}pvehost:nfs: ${count} mount(s) for ${BL}${CONSUMER}${CL}"
nfs_service_check "${CONSUMER}" || die "pvehost:nfs: ${CONSUMER}'s mounts are refused (above) — nothing was changed"
[[ "$(nfs_consumer_os "${CONSUMER}")" != "other" ]] || die "pvehost:nfs mounts only NixOS and Debian guests (ADR-029 D10)"
nfs_service_build_exports "${CONSUMER}" || die "pvehost:nfs: a node's exports did not converge (above)"
nfs_service_write_guest "${CONSUMER}"
