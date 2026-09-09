#!/usr/bin/env bash
#
# TAPPaaS Backup Module Update
#
# Three jobs (ADR-012):
#   * §2.2/§2.3 — migrate a legacy placement state in place (local → node:<name>,
#          remote-only → external), backfill a pre-ADR-012 install, and promote a
#          shim to a real PBS once a tankc pool appears.
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
# shellcheck source=lib/pbs-immutable.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-immutable.sh"

ZONE="$(get_config_value 'zone0' 'mgmt')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"

# Migrate a legacy state in place before anything reads it (ADR-012 §4.1, D22):
# local → node:<name> (datastore untouched), remote-only → external. A
# pre-ADR-012 install has no marker at all and is handled below.
LEGACY_NODE=""
if [[ "$(pbs_placement_state)" == "local" ]]; then
  LEGACY_NODE="$(pbs_legacy_pbs_node "${ZONE}")"
fi
pbs_migrate_placement_state "" "${LEGACY_NODE}" >/dev/null || warn "Could not migrate legacy placement state"
STATE="$(pbs_placement_state)"

# ── external: no local PBS to touch; clients push to the consumed PBS ──
if [[ "${STATE}" == "external" ]]; then
    info "Backup placement is ${BL}external${CL} (${BGN}$(pbs_pbs_url)${CL}) — no local PBS to update."
    # Clients still push to it (§1.4), so keep client coverage in step with
    # current cluster membership (#382).
    pbs_client_reconcile "${ZONE}" "${IMAGE_LOCATION}" \
        || warn "One or more nodes could not be reconciled for proxmox-backup-client (see above)"
    exit 0
fi

# ── empty or shim: (re-)derive the state (§2.2 rule 3) ────────────────
# Empty = a pre-ADR-012 install (a real local PBS with no marker) or a fresh
# config; shim = a placeholder waiting for storage. Both re-derive on every
# update, so a shim promotes in place the moment a tankc pool appears — and a
# legacy install is backfilled to node:<name> without a promotion-reinstall.
if [[ -z "${STATE}" ]]; then
    # Pre-ADR-012 install: a real local PBS with no marker. Name the node it
    # actually runs on and record it — no discovery, no move, no reinstall.
    PNODE="$(pbs_legacy_pbs_node "${ZONE}")"
    info "No placement state recorded — backfilling to ${BGN}node:${PNODE}${CL}; the datastore is left where it is."
    pbs_write_placement_state "node:${PNODE}"
    STATE="node:${PNODE}"
fi

if [[ "${STATE}" == "shim" ]]; then
    NODE_CONSTRAINT="$(get_config_value 'node' '')"
    read -r MODE PSTORAGE < <(pbs_resolve_placement_state "${STATE}" "${NODE_CONSTRAINT}" "${ZONE}" "$(get_node_hostname 0)")
    if PNODE="$(pbs_state_node "${MODE}")"; then
        info "${BOLD}Storage now available (${BGN}${PNODE}:${PSTORAGE}${CL}${BOLD}) — promoting shim → real PBS${CL}"
        # install.sh is idempotent: it realizes the datastore + reconciles
        # clients and rewrites .placementState. Dependent modules
        # (dependsOn:backup) are untouched. (Run via `bash` — install.sh's
        # shebang isn't on line 1.)
        exec bash "${MODULE_DIR}/install.sh" backup
    else
        warn "Backup is still a shim (no usable tankc pool found) — nothing to update."
        exit 0
    fi
fi

# ── local PBS: heal client coverage (P3), then keep the job consistent ──
pbs_client_reconcile "${ZONE}" "${IMAGE_LOCATION}" \
    || warn "One or more nodes could not be reconciled for proxmox-backup-client (see above)"

info "${BOLD}Ensuring every opted-in VM is registered in the managed backup job${CL}"
pbs_ensure_declared

# Retrofit the ZFS-mount ordering on already-deployed PBS servers (issue #230);
# idempotent, so this is a no-op once the drop-ins are in place.
pbs_ensure_zfs_ordering

# Retrofit datastore integrity verification (verify-job + verify-new, issue #228)
# on already-deployed PBS servers; idempotent.
pbs_ensure_verify

# Apply/retrofit opt-in ZFS-snapshot immutability (ADR-012 §3.5 / #389); no-op
# unless backup.json .immutableSnapshots.enabled.
pbs_immutable_from_config "$(get_config_value 'storage' 'tankc1')" "$(pbs_storage_name)" \
    || warn "Could not configure immutable snapshots"

info "  ${GN}✓${CL} Backup module update completed"
