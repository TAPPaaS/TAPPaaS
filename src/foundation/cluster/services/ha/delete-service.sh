#!/usr/bin/env bash
#
# TAPPaaS Cluster HA Service - Delete
#
# Removes High Availability configuration for a consuming module's VM.
# Removes: HA resource, HA node-affinity rule, ZFS replication jobs.
#
# Usage: delete-service.sh <module-name>
# Arguments:
#   module-name - Name of the module whose HA config should be removed
#                 (must have a <module-name>.json in /home/tappaas/config)
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Removes HA configuration for the specified module."
    exit 1
fi

. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="$1"
MGMTVLAN="mgmt"

VMID=$(get_config_value 'vmid')
NODE=$(get_config_value 'node' "$(get_node_hostname 0)")
HANODE=$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")

NODE_FQDN="${NODE}.${MGMTVLAN}.internal"
HA_RULE_NAME="ha-${MODULE_NAME}"

debug "Removing HA configuration for module: ${MODULE_NAME} (VMID: ${VMID})"

# Remove VM from HA resources
if ssh root@"${NODE_FQDN}" "ha-manager config" 2>/dev/null | grep -q "^vm:${VMID}"; then
    debug "  Removing VM from HA resources..."
    ssh root@"${NODE_FQDN}" "ha-manager remove vm:${VMID}" 2>/dev/null || true
    debug "  HA resource removed"
else
    debug "  VM not in HA resources, nothing to remove"
fi

# Remove HA rule
if ssh root@"${NODE_FQDN}" "ha-manager rules list" 2>/dev/null | grep -q "${HA_RULE_NAME}"; then
    debug "  Removing HA rule: ${HA_RULE_NAME}"
    ssh root@"${NODE_FQDN}" "ha-manager rules remove ${HA_RULE_NAME}" 2>/dev/null || true
else
    debug "  No HA rule found for this module"
fi

# Remove all replication jobs for this VM.
#
# This has to be driven to completion HERE, before cluster:vm destroys the
# guest. Two Proxmox behaviours make the naive call leak storage:
#
#   * "pvesr delete <id> --force 1" drops the jobconfig entry but skips the
#     cleanup entirely ("will remove the jobconfig entry, but will not cleanup").
#   * Plain "pvesr delete <id>" only MARKS the job (remove_job=full); the actual
#     cleanup is a background task run by pvescheduler. "qm destroy" calls
#     PVE::ReplicationConfig::remove_vmid_jobs(), which deletes every job entry
#     for the VMID outright — so if the guest is destroyed first, the marked job
#     disappears before it ever runs.
#
# Either way the replicated volumes and their __replicate_<job>__ snapshots are
# stranded on the target node. When the VMID is reused (the deep-test fixtures
# recycle 911/921 on every run) the new job finds a same-named dataset carrying
# a foreign snapshot and fails "No common base snapshot" on every schedule tick,
# mailing the operator daily.
#
# So: mark the job, then run it immediately ("pvesr run --id" executes pending
# removal jobs), then verify it is gone.
list_repl_jobs() {
    ssh root@"${NODE_FQDN}" "pvesh get /cluster/replication --output-format json" 2>/dev/null \
        | jq -r ".[] | select(.guest == ${VMID}) | .id" 2>/dev/null || true
}

REPL_JOBS=$(list_repl_jobs)
if [[ -n "${REPL_JOBS}" ]]; then
    for job_id in ${REPL_JOBS}; do
        debug "  Removing replication job: ${job_id} (with target cleanup)"

        # Mark for removal (remove_job=full: local snapshots + remote volumes).
        if ! ssh root@"${NODE_FQDN}" "pvesr delete ${job_id}"; then
            warn "  Could not mark replication job ${job_id} for removal"
            continue
        fi

        # Run it now, synchronously, rather than waiting for pvescheduler —
        # the guest is about to be destroyed.
        if ! ssh root@"${NODE_FQDN}" "pvesr run --id ${job_id}"; then
            warn "  Replication job ${job_id} removal did not complete cleanly"
        fi
    done

    # Anything still listed means the cleanup did not finish; the operator has
    # to remove the stale volumes on the target before this VMID is reused.
    LEFTOVER=$(list_repl_jobs)
    if [[ -n "${LEFTOVER}" ]]; then
        warn "  Replication job(s) still present after removal: ${LEFTOVER//$'\n'/ }"
        warn "  Replicated volumes for VM ${VMID} may remain on the target node."
        warn "  Check with: zfs list -t all | grep vm-${VMID}-"
    else
        debug "  Replication jobs removed (target volumes cleaned up)"
    fi
else
    debug "  No replication jobs found"
fi

debug "HA configuration removed for ${MODULE_NAME}"
