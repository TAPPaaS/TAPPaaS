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
NODE=$(get_config_value 'node' 'tappaas1')
HANODE=$(get_config_value 'HANode' 'NONE')

NODE_FQDN="${NODE}.${MGMTVLAN}.internal"
HA_RULE_NAME="ha-${MODULE_NAME}"

info "Removing HA configuration for module: ${MODULE_NAME} (VMID: ${VMID})"

# If no HA was configured, nothing to do
if [[ "${HANODE}" == "NONE" || -z "${HANODE}" ]]; then
    info "  No HANode configured — nothing to remove"
    exit 0
fi

# Remove VM from HA resources
if ssh root@"${NODE_FQDN}" "ha-manager config" 2>/dev/null | grep -q "^vm:${VMID}"; then
    info "  Removing VM from HA resources..."
    ssh root@"${NODE_FQDN}" "ha-manager remove vm:${VMID}" 2>/dev/null || true
    info "  HA resource removed"
else
    info "  VM not in HA resources, nothing to remove"
fi

# Remove HA rule
if ssh root@"${NODE_FQDN}" "ha-manager rules list" 2>/dev/null | grep -q "${HA_RULE_NAME}"; then
    info "  Removing HA rule: ${HA_RULE_NAME}"
    ssh root@"${NODE_FQDN}" "ha-manager rules remove ${HA_RULE_NAME}" 2>/dev/null || true
else
    info "  No HA rule found for this module"
fi

# Remove all replication jobs for this VM
REPL_JOBS=$(ssh root@"${NODE_FQDN}" "pvesh get /cluster/replication --output-format json" 2>/dev/null \
    | jq -r ".[] | select(.guest == ${VMID}) | .id" 2>/dev/null || echo "")
if [[ -n "${REPL_JOBS}" ]]; then
    for job_id in ${REPL_JOBS}; do
        info "  Removing replication job: ${job_id}"
        ssh root@"${NODE_FQDN}" "pvesr delete ${job_id} --force 1" 2>/dev/null || true
    done
    info "  Replication jobs removed"
else
    info "  No replication jobs found"
fi

info "HA configuration removed for ${MODULE_NAME}"
