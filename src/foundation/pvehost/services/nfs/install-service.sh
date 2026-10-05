#!/usr/bin/env bash
#
# pvehost:nfs — install-service (ADR-029 v0.8). Gives a consumer the NFS shares its
# config."pvehost:nfs".mounts[] names — by share name, wherever they live:
#
#   1. every mount passes its shape check; where its share exists, the two-key
#      check (D3, D11). A share no server declares leaves the mount PENDING: the
#      install goes ahead and the directory stays local
#   2. each server that grants the consumer converges (D11, D16)
#   3. per mount: mounted, or migrated into when its directory already holds data
#      and consent was given (D14)
#   4. the mounts are written into the guest (D10): the NixOS fragment, applied by
#      the rebuild that install/update run after the services, or Debian's fstab
#
# Never creates a share and never destroys share data. Idempotent.
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
nfs_service_converge "${CONSUMER}"
