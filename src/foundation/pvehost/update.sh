#!/usr/bin/env bash
# pvehost update — converge what a node instance declares about itself.
#
# OS patching is still not here (ADR-026 D4 stage 1, #665): a cluster node's OS is
# patched by the cluster module's update (update-os.sh, Step 1), with the
# cluster's reboot pass; stage 2 moves that behind this script so a node and a
# debianhost are patched by one path with one set of consent rules.
#
# What it does converge is the node's NFS exports (ADR-029, #766): each entry in
# its nfs.exports[] becomes a dataset <pool>/tappaas-nfs/<name>, shared through
# ZFS sharenfs to the consumers it grants. A node with no exports is untouched.
#
# Usage: update.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/pvehost-lib.sh"
. "${HERE}/lib/nfs-lib.sh"
. "${HERE}/lib/nfs-node.sh"

pn_load "$1"
debug "  ${INSTANCE}: OS patching is the cluster module's (update-os.sh) — not done here (ADR-026 D4 stage 1)"

if ! pn_reachable; then
    # A node that is down has nothing converged; that is only an error when it
    # declares exports its consumers are waiting for.
    [[ -z "$(nfs_exports "${INSTANCE}")" ]] || die "cannot log in to root@${ADDRESS} with the mothership's key — its NFS exports were not converged"
    warn "  ${INSTANCE}: not reachable — nothing to converge"
    exit 0
fi
nfs_node_reconcile
