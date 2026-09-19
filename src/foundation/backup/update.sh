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
# shellcheck source=lib/pbs-dns.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-dns.sh"
# shellcheck source=lib/pbs-host.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-host.sh"

INSTANCE="$(pbs_instance "${1:-}")"

ZONE="$(get_config_value 'zone0' 'mgmt')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"

# Migrate a legacy state in place before anything reads it (ADR-012 §4.1, D22):
# local → node:<name> (datastore untouched), remote-only → external. A
# pre-ADR-012 install has no marker at all and is handled below.
LEGACY_NODE=""
if [[ "$(pbs_placement_state)" == "local" ]]; then
    LEGACY_NODE="$(pbs_legacy_pbs_node "${ZONE}")"

    # A legacy `local` state does not distinguish "PBS on a cluster node" from
    # "PBS on a standalone host that happens to answer at backup.mgmt.internal".
    # To the client modules those look identical, so the difference survives
    # unnoticed until a migration writes `node:<name>` and asserts a cluster
    # membership that was never true. Check before asserting it.
    if [[ -n "${LEGACY_NODE}" ]]; then
        # Tested context (`|| rc=$?`), not a bare call: under `set -e` a bare
        # call ends the script on the very returns this case exists to read —
        # 1 (not a member) and 2 (cluster unreachable) — so only the 0) branch
        # was ever reachable (#625).
        _member_rc=0
        pbs_node_is_cluster_member "${LEGACY_NODE}" "${ZONE}" || _member_rc=$?
        case "${_member_rc}" in
            0) : ;;   # a real cluster member — the ordinary node:<name> case
            1)
                # Not in the cluster: this PBS is not ours to place. `external`
                # (consume it by URL) is the truthful state, and it is what the
                # clients have been doing all along.
                _pbs_dns="$(pbs_dns_name "${INSTANCE}" "${ZONE}")"
                warn "PBS host '${LEGACY_NODE}' is NOT a member of this cluster."
                warn "  This is an externally-managed PBS, not one this module placed."
                warn "  Recording it as ${BL}placementState:external${CL} with pbsUrl ${BL}${_pbs_dns}${CL}"
                warn "  (nothing moves: the datastore, its contents and the backup job are untouched)."
                # Leave on failure rather than falling through: the migrate
                # below still sees `local` and would write the node:<name> this
                # branch exists to prevent (or `shim`, when .node was blanked).
                pbs_adopt_external_pbs "${_pbs_dns}" || {
                    warn "  Could not record the external placement — leaving the state as it was."
                    exit 0
                }
                LEGACY_NODE=""
                ;;
            *)
                warn "Could not reach the cluster to check whether '${LEGACY_NODE}' is a member —"
                warn "  leaving the placement state alone rather than guessing. Re-run when it is reachable."
                exit 0
                ;;
        esac
    fi
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
    # Pre-ADR-012 install: a real local PBS with no marker. Name the Host it
    # actually runs on and record it — no discovery, no move, no reinstall.
    # Ask the Hosts themselves first (§2.2 rule 3, #602): the legacy guess below
    # ends at "the first mgmt node", which is wrong for a PBS on a machine that
    # is not a cluster member (§1.3).
    if SERVING="$(pbs_find_serving_pbs "$(get_config_value 'node' '')" "${ZONE}" "$(get_node_hostname 0)")"; then
        if [[ "${SERVING}" == unmanaged\ * ]]; then
            error "A PBS answers at ${SERVING#unmanaged } but no Host this Site manages holds the datastore — not recording a placement (ADR-012 §2.2, #602)."
            error "  If that is the PBS to use: module-manager module modify backup --set placementState=external --set pbsUrl=${SERVING#unmanaged }"
            exit 1
        fi
        PNODE="${SERVING}"
    else
        PNODE="$(pbs_legacy_pbs_node "${ZONE}")"
    fi
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
        exec bash "${MODULE_DIR}/install.sh" "${INSTANCE}"
    else
        warn "Backup is still a shim (no usable tankc pool found) — nothing to update."
        exit 0
    fi
fi

# ── local PBS: its name follows its Host (#612) — also migrates the A record
# every install before #612 wrote. Not fatal: clients keep resolving the old
# record until it is replaced, and the next update retries.
pbs_dns_ensure "${INSTANCE}" "${ZONE}" "$(pbs_state_node "$(pbs_placement_state)" || true)" \
    || warn "The PBS DNS name was not updated (see above) — clients still reach it by the old record"

# ── local PBS: something patches its Host (#603) — the cluster module for a
# node, the Host's own debianhost instance for a machine (adopted if needed).
pbs_host_ensure_patched "$(pbs_state_node "$(pbs_placement_state)" || true)" "${ZONE}" || true

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
