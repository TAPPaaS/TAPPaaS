#!/usr/bin/env bash
#
# nfs-server.sh — pvehost's NFS server hook (ADR-029 v0.9 D19). storage-manager and
# the node's own update call it to build, on one node, what config/shares.json
# declares for it; it never decides what to serve, only how on a PVE node.
#
#   converge <instance> [--exclude <consumer>]...   build and share every share
#                       declared for the node; unshare (keep) what no longer is.
#                       --exclude leaves a consumer out of every client list (D16)
#   test <instance>     the live state against the declarations (D16 drift)
#   subdir <instance> <share> <subdir>   the subdir exists, owned by the owner (D15)
#   purge <instance> <share>             destroy an orphan's dataset (D6)
#
# Runs on the mothership as the tappaas operator; reaches the node as root by key.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERB="${1:-}"; INSTANCE="${2:-}"
[[ -n "${VERB}" && -n "${INSTANCE}" ]] || { echo "usage: $0 converge|test|subdir|purge <instance> [...]" >&2; exit 2; }
shift 2
REST=("$@"); set --          # common-install-routines.sh reads $1 as a module name
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/../lib/pvehost-lib.sh"
# The share model lives in the storage module (ADR-029 D1); find it through its
# registration, as any module's services are found.
STORAGE_DIR="$(get_module_dir storage 2>/dev/null)" || STORAGE_DIR=""
[[ -n "${STORAGE_DIR}" && -f "${STORAGE_DIR}/lib/nfs-lib.sh" ]] || STORAGE_DIR="${HERE}/../../storage"
. "${STORAGE_DIR}/lib/nfs-lib.sh"
. "${HERE}/../lib/nfs-node.sh"

# The node is read from its own file — never through pn_load, which would read the
# caller's $JSON.
ADDRESS="$(jq -r '.address // empty' "${NFS_CONFIG_DIR}/${INSTANCE}.json" 2>/dev/null)"
[[ -n "${ADDRESS}" ]] || die "${INSTANCE}: no address in config/${INSTANCE}.json"
pn_reachable || die "${INSTANCE}: root@${ADDRESS} does not accept the mothership's key"
set -- "${REST[@]}"

case "${VERB}" in
    converge)
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                --exclude) NFS_EXCLUDE_CONSUMERS="${NFS_EXCLUDE_CONSUMERS:-} ${2:?--exclude needs a consumer}"; shift 2 ;;
                *) die "converge: unknown argument '$1'" ;;
            esac
        done
        export NFS_EXCLUDE_CONSUMERS
        nfs_node_reconcile ;;
    test)
        fails=0
        while IFS= read -r e <&3; do
            [[ -n "${e}" ]] || continue
            name="$(jq -r .name <<< "${e}")"; ds="$(nfs_dataset "$(jq -r .pool <<< "${e}")" "${name}")"
            mnt="$(pn_ssh "zfs get -H -o value mountpoint '${ds}' 2>/dev/null")" || mnt=""
            if [[ "${mnt}" != "${NFS_MOUNT_ROOT}/${name}" ]]; then error "  ✗ share ${name}: ${ds} is ${mnt:-not built}"; fails=$((fails + 1)); continue; fi
            want="$(nfs_node_expected_share "${e}")"; live="$(pn_ssh "zfs get -H -o value sharenfs '${ds}'")"
            if [[ "${live}" == "${want}" ]]; then info "  ${GN}✓${CL} share ${name}: built at ${mnt}, client list as declared"
            else error "  ✗ share ${name}: client list drift (D16) — live '${live}', declared '${want}'"; fails=$((fails + 1)); fi
        done 3< <(nfs_exports "${INSTANCE}")
        (( fails == 0 )) ;;
    subdir)
        [[ "$#" -eq 2 ]] || die "subdir <instance> <share> <subdir>"
        nfs_node_subdir "$1" "$2" ;;
    purge)
        [[ "$#" -eq 1 ]] || die "purge <instance> <share>"
        nfs_node_purge "$1" ;;
    *) die "unknown verb '${VERB}' (converge|test|subdir|purge)" ;;
esac
