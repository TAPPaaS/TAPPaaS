#!/usr/bin/env bash
#
# cluster:storage NFS backend — pure computation, no SSH/mount/fstab side
# effects. Prints one JSON line describing the fileSystems entry for a named
# NFS share: {"mountPoint","access","device","fsType":"nfs","options"}.
# The dispatcher (services/storage/*.sh) turns this into a NixOS snippet and
# writes it into the consuming module's own .nix source.
#
# Usage: mount-params.sh <share-name> <mount-point> <access> <node-fqdn>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/storage-zone.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/storage-zone.sh"

NAME="${1:?Usage: mount-params.sh <share-name> <mount-point> <access> <node-fqdn>}"
MOUNT_POINT="${2:?}"
ACCESS="${3:-rw}"
readonly NAME MOUNT_POINT ACCESS

SHARES_FILE="${CONFIG_DIR}/nfs-shares.json"
[[ -f "${SHARES_FILE}" ]] || die "nfs-shares.json not found at ${SHARES_FILE}"

SHARE_JSON="$(jq -c --arg n "${NAME}" '.[$n] // empty' "${SHARES_FILE}")"
[[ -n "${SHARE_JSON}" ]] || die "share '${NAME}' not found in ${SHARES_FILE}"

TYPE="$(jq -r '.type' <<<"${SHARE_JSON}")"

if [[ "${TYPE}" == "external" ]]; then
    HOST="$(jq -r '.host' <<<"${SHARE_JSON}")"
    EXPORT_PATH="$(jq -r '.export' <<<"${SHARE_JSON}")"
    DEVICE="${HOST}:${EXPORT_PATH}"
else
    NODE="$(jq -r '.node' <<<"${SHARE_JSON}")"
    TANK="$(jq -r '.tank' <<<"${SHARE_JSON}")"
    NODE_IP="$(storage_node_ip "${NODE}")"
    DEVICE="${NODE_IP}:/${TANK}/${NAME}"
fi

jq -nc \
    --arg mountPoint "${MOUNT_POINT}" \
    --arg access "${ACCESS}" \
    --arg device "${DEVICE}" \
    '{
        mountPoint: $mountPoint,
        access: $access,
        device: $device,
        fsType: "nfs",
        options: ["nofail", "noatime", "x-systemd.automount", "_netdev"]
    }'
