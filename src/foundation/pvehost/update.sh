#!/usr/bin/env bash
# pvehost update — converge what a node instance is responsible for.
#
# OS patching is still not here (ADR-026 D4 stage 1, #665): a cluster node's OS is
# patched by the cluster module's update (update-os.sh, Step 1), with the
# cluster's reboot pass; stage 2 moves that behind this script so a node and a
# debianhost are patched by one path with one set of consent rules.
#
# What it does converge is the NFS shares config/shares.json declares for this
# node (ADR-029 v0.9 D19), through the node's own server hook — so the sweep keeps
# every node's shares built without storage-manager having run. A node with no
# shares declared for it is untouched.
#
# Usage: update.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/pvehost-lib.sh"

pn_load "$1"
debug "  ${INSTANCE}: OS patching is the cluster module's (update-os.sh) — not done here (ADR-026 D4 stage 1)"

declared="$(jq -r --arg i "${INSTANCE}" '[.nfs.shares // {} | to_entries[] | select(.value.server == $i)] | length' \
    "${CONFIG_DIR}/shares.json" 2>/dev/null || echo 0)"
if ! pn_reachable; then
    # A node that is down converges nothing; that is only an error when shares its
    # consumers are waiting for are declared for it.
    [[ "${declared}" == "0" ]] || die "cannot log in to root@${ADDRESS} with the mothership's key — its ${declared} NFS share(s) were not converged"
    warn "  ${INSTANCE}: not reachable — nothing to converge"
    exit 0
fi
# The hook also unshares (and keeps) what is no longer declared here, so it runs
# even when nothing is declared — a node whose last share moved away is cleaned.
"${HERE}/storage/nfs-server.sh" converge "${INSTANCE}"
