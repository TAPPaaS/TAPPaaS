#!/usr/bin/env bash
#
# TAPPaaS Cluster HA Service - Update
#
# Manages Proxmox HA rules and ZFS replication for a consuming module.
# Based on the module's HANode field:
#   - If HANode is "NONE" or not present: Remove any existing HA/replication config
#   - If HANode is set to a valid node: Create/update HA rule and replication
#
# The script uses the replicationSchedule field (default: */15) for replication interval.
#
# Note: Proxmox 8.x uses rules-based HA (node-affinity rules) instead of groups.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="$1"
MGMTVLAN="mgmt"

# Get required values from JSON
VMID=$(get_config_value 'vmid')
NODE=$(get_config_value 'node' 'tappaas1')
HANODE=$(get_config_value 'HANode' 'NONE')
REPLICATION_SCHEDULE=$(get_config_value 'replicationSchedule' '*/15')
STORAGE=$(get_config_value 'storage' 'tanka1')

info "${BOLD}Updating HA configuration for module: ${BGN}${MODULE_NAME}${CL}"
info "  VMID: $VMID"
info "  Primary Node: $NODE"
info "  HA Node: $HANODE"
info "  Replication Schedule: $REPLICATION_SCHEDULE"
info "  Storage: $STORAGE"

# Build FQDN for primary node
NODE_FQDN="${NODE}.${MGMTVLAN}.internal"

# HA rule name follows pattern: ha-<module-name>
HA_RULE_NAME="ha-${MODULE_NAME}"

# Check if VM exists
info "\nChecking if VM $VMID exists on node $NODE..."
if ! ssh root@"$NODE_FQDN" "qm status $VMID" &>/dev/null; then
  error "VM $VMID does not exist on node $NODE"
  exit 1
fi
info "  VM $VMID found"

# Function to remove HA configuration
remove_ha_config() {
  info "\n${BOLD}Removing HA configuration for VM $VMID..."

  # Check if VM is in HA resources
  if ssh root@"$NODE_FQDN" "ha-manager config" 2>/dev/null | grep -q "^vm:$VMID"; then
    info "  Removing VM from HA resources..."
    ssh root@"$NODE_FQDN" "ha-manager remove vm:$VMID" 2>/dev/null || true
    info "  HA resource removed"
  else
    info "  VM not in HA resources, nothing to remove"
  fi

  # Check for and remove HA rule
  info "\nChecking for HA rules..."
  # ha-manager rules list outputs a table with rule names - grep for the rule name
  if ssh root@"$NODE_FQDN" "ha-manager rules list" 2>/dev/null | grep -q "${HA_RULE_NAME}"; then
    info "  Removing HA rule: $HA_RULE_NAME"
    ssh root@"$NODE_FQDN" "ha-manager rules remove $HA_RULE_NAME" 2>/dev/null || warn "Could not remove HA rule $HA_RULE_NAME"
  else
    info "  No HA rule found for this module"
  fi

  # Check for and remove replication jobs
  info "\nChecking for replication jobs..."
  REPL_JOBS=$(ssh root@"$NODE_FQDN" "pvesh get /cluster/replication --output-format json" 2>/dev/null | jq -r ".[] | select(.guest == $VMID) | .id" 2>/dev/null || echo "")
  if [ -n "$REPL_JOBS" ]; then
    for job_id in $REPL_JOBS; do
      info "  Removing replication job: $job_id"
      ssh root@"$NODE_FQDN" "pvesr delete $job_id --force 1" 2>/dev/null || warn "Could not remove replication job $job_id"
    done
    info "  Replication jobs removed"
  else
    info "  No replication jobs found"
  fi
}

# Function to create/update HA configuration
create_ha_config() {
  local ha_node="$1"

  info "\n${BOLD}Configuring HA for VM $VMID with secondary node: ${BGN}${ha_node}${CL}"

  # Validate HA node is different from primary
  if [ "$ha_node" == "$NODE" ]; then
    error "HANode ($ha_node) must be different from primary node ($NODE)"
    exit 1
  fi

  # Check HA node is reachable
  HA_NODE_FQDN="${ha_node}.${MGMTVLAN}.internal"
  info "  Checking HA node $ha_node is reachable..."
  if ! ssh root@"$HA_NODE_FQDN" "hostname" &>/dev/null; then
    error "Cannot reach HA node: $HA_NODE_FQDN"
    exit 1
  fi
  info "  HA node is reachable"

  # Check storage exists on HA node
  info "  Checking storage $STORAGE exists on $ha_node..."
  if ! ssh root@"$HA_NODE_FQDN" "pvesm status --storage $STORAGE" &>/dev/null; then
    error "Storage $STORAGE does not exist on node $ha_node"
    exit 1
  fi
  info "  Storage verified on HA node"

  # Add VM to HA if not already present
  info "\n  Adding VM $VMID to HA resources..."
  if ssh root@"$NODE_FQDN" "ha-manager config" 2>/dev/null | grep -q "^vm:$VMID"; then
    info "  VM already in HA resources, updating..."
    ssh root@"$NODE_FQDN" "ha-manager set vm:$VMID --state started" 2>/dev/null || {
      error "Failed to update HA resource"
      exit 1
    }
  else
    ssh root@"$NODE_FQDN" "ha-manager add vm:$VMID --state started" 2>/dev/null || {
      error "Failed to add VM to HA"
      exit 1
    }
  fi
  info "  VM added to HA resources"

  # Create or update node-affinity rule
  # Priority: primary node gets priority 2, HA node gets priority 1
  info "\n  Setting up node-affinity rule: $HA_RULE_NAME..."

  # Check if rule exists - ha-manager rules list outputs a table with rule names
  if ssh root@"$NODE_FQDN" "ha-manager rules list" 2>/dev/null | grep -q "${HA_RULE_NAME}"; then
    info "  Updating existing HA rule..."
    ssh root@"$NODE_FQDN" "ha-manager rules set node-affinity $HA_RULE_NAME --nodes ${NODE}:2,${ha_node}:1 --resources vm:$VMID" 2>/dev/null || {
      error "Failed to update HA rule"
      exit 1
    }
  else
    info "  Creating new HA rule..."
    ssh root@"$NODE_FQDN" "ha-manager rules add node-affinity $HA_RULE_NAME --nodes ${NODE}:2,${ha_node}:1 --resources vm:$VMID" 2>/dev/null || {
      error "Failed to create HA rule"
      exit 1
    }
  fi
  info "  Node-affinity rule configured: primary=$NODE (priority 2), failover=$ha_node (priority 1)"

  # Setup replication
  info "\n  Setting up ZFS replication to $ha_node..."

  # Check for existing replication job
  EXISTING_REPL=$(ssh root@"$NODE_FQDN" "pvesh get /cluster/replication --output-format json" 2>/dev/null | jq -r ".[] | select(.guest == $VMID) | .id" 2>/dev/null || echo "")

  if [ -n "$EXISTING_REPL" ]; then
    info "  Updating existing replication job: $EXISTING_REPL"
    ssh root@"$NODE_FQDN" "pvesr update $EXISTING_REPL --schedule '$REPLICATION_SCHEDULE'" 2>/dev/null || {
      warn "Could not update replication schedule, removing and recreating..."
      ssh root@"$NODE_FQDN" "pvesr delete $EXISTING_REPL" 2>/dev/null || true
      EXISTING_REPL=""
    }
  fi

  if [ -z "$EXISTING_REPL" ]; then
    # Create new replication job
    # Job ID format: <vmid>-<index>
    # Syntax: pvesr create-local-job <id> <target> [OPTIONS]
    JOB_ID="${VMID}-0"
    info "  Creating replication job: $JOB_ID"
    ssh root@"$NODE_FQDN" "pvesr create-local-job $JOB_ID $ha_node --schedule '$REPLICATION_SCHEDULE'" 2>/dev/null || {
      error "Failed to create replication job"
      exit 1
    }
  fi
  info "  Replication configured with schedule: $REPLICATION_SCHEDULE"
}

# Main logic
if [ "$HANODE" == "NONE" ] || [ -z "$HANODE" ]; then
  info "\n${BOLD}HANode is 'NONE' - removing any existing HA configuration"
  remove_ha_config
else
  create_ha_config "$HANODE"
fi

info "\n${GN}${BOLD}HA configuration update completed for ${MODULE_NAME}${CL}"
