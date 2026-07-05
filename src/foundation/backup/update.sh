#!/usr/bin/env bash
#
# TAPPaaS Backup Module Update
#
# Three jobs (ADR-012):
#   * P2 — promote a shim to a real PBS in place once a tankc pool appears
#          (re-resolves the configured placement policy; auto/node: promote,
#          an explicit `shim` policy stays a shim).
#   * P3 — reconcile proxmox-backup-client across CURRENT cluster membership so
#          a node added after install gets its client (#382).
#   * Keep the managed PBS job consistent: alwaysBackup VMs, ZFS-mount ordering
#          (#230), datastore verification (#228).
#
# Per-module membership (dependsOn backup:vm) is maintained by the consuming
# modules' own update via backup:vm update-service.sh. See issues #200, #382.
#
# Usage: update.sh [module-name]
#

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/pbs-job.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-job.sh"
# shellcheck source=lib/pbs-placement.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-placement.sh"
# shellcheck source=lib/pbs-client.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-client.sh"

ZONE="$(get_config_value 'zone0' 'mgmt')"
STATE="$(pbs_placement_state)"

# ── remote-only: no local PBS to touch (off-site push is P4) ──────────
if [[ "${STATE}" == "remote-only" ]]; then
    info "Backup placement is ${BL}remote-only${CL} — no local PBS to update (off-site push is ADR-012 P4)."
    exit 0
fi

# Legacy deployments (installed before ADR-012) have no placementState. They were
# always a real local PBS — treat empty as local and backfill the marker. Do NOT
# route them through promotion (that would re-run a full install unnecessarily).
if [[ -z "${STATE}" ]]; then
    info "No placement state recorded — treating as an existing local PBS (backfilling marker)."
    pbs_write_placement_state local
    STATE="local"
fi

# ── P2: promote a shim → real PBS once a tankc pool appears ───────────
# Only an explicit shim promotes. Re-resolve the CONFIGURED policy: auto/node:
# now find storage and promote; an explicitly-chosen `shim` policy stays a shim.
if [[ "${STATE}" == "shim" ]]; then
    POLICY="$(placement_policy)"
    PREFERRED_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
    read -r MODE PNODE PSTORAGE < <(pbs_discover_placement "${POLICY}" "${PREFERRED_NODE}" "${ZONE}")
    if [[ "${MODE}" == "local" ]]; then
        info "${BOLD}Storage now available (${BGN}${PNODE}:${PSTORAGE}${CL}${BOLD}) — promoting shim → local PBS${CL}"
        # install.sh is idempotent: it realizes the datastore + reconciles clients
        # and rewrites .placementState=local. Dependent modules (dependsOn:backup)
        # are untouched. (Run via `bash` — install.sh's shebang isn't on line 1.)
        exec bash "${MODULE_DIR}/install.sh" backup
    fi
    warn "Backup is still a shim (policy ${POLICY}: no usable tankc pool found) — nothing to update."
    exit 0
fi

# ── local PBS: heal client coverage (P3), then keep the job consistent ──
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"
pbs_client_reconcile "${ZONE}" "${IMAGE_LOCATION}" \
    || warn "One or more nodes could not be reconciled for proxmox-backup-client (see above)"

info "${BOLD}Ensuring alwaysBackup VMs are registered in the managed backup job${CL}"
pbs_ensure_always

# Retrofit the ZFS-mount ordering on already-deployed PBS servers (issue #230);
# idempotent, so this is a no-op once the drop-ins are in place.
pbs_ensure_zfs_ordering

# Retrofit datastore integrity verification (verify-job + verify-new, issue #228)
# on already-deployed PBS servers; idempotent.
pbs_ensure_verify

info "  ${GN}✓${CL} Backup module update completed"
