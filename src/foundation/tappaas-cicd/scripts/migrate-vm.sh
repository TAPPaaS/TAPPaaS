#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Migrate
#
# Migrates VMs between Proxmox cluster nodes. Attempts live migration first;
# if it fails, falls back to shutdown → offline migrate → start.
#
# Usage:
#   migrate-vm.sh <module-name>           Migrate module VM to its HANode
#   migrate-vm.sh --node <node-name>      Migrate all VMs that belong on <node> back to it
#
# Arguments:
#   module-name   Name of the module (must have config in ~/config with HANode)
#
# Options:
#   --node <name>   Target node name (e.g., tappaas1). Finds all modules whose
#                   configured 'node' matches and migrates them there if they
#                   are currently running elsewhere.
#   --offline       Skip live migration attempt; go straight to offline migration
#   -h, --help      Show this help message
#
# Examples:
#   migrate-vm.sh identity               # Migrate identity VM to its HANode
#   migrate-vm.sh --node tappaas1        # Bring all tappaas1 VMs back home
#   migrate-vm.sh --offline identity     # Force offline migration
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'
readonly BOLD=$'\033[1m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Configuration ────────────────────────────────────────────────────

readonly CONFIG_DIR="/home/tappaas/config"
readonly MGMT="mgmt"

# Global state for HA save/restore
_HA_RULE_NAME=""
_HA_RULE_NODES=""

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: migrate-vm.sh <module-name>
       migrate-vm.sh --node <node-name>

Migrate VMs between Proxmox cluster nodes.

Modes:
    <module-name>         Migrate a single module's VM to its HANode
    --node <node-name>    Migrate all VMs that belong on <node> back to it

Options:
    --offline             Skip live migration attempt; use offline migration
    -h, --help            Show this help message

Examples:
    migrate-vm.sh identity               # Migrate identity to its HANode
    migrate-vm.sh --node tappaas1        # Return all tappaas1 VMs home
    migrate-vm.sh --offline identity     # Force offline migration
EOF
}

# ── Helper functions ─────────────────────────────────────────────────

# Find which node a VM is currently running on.
# Arguments: <vmid>
# Outputs: node name or empty string if VM not found/not running
get_vm_current_node() {
    local vmid="$1"
    local first_node

    # Find a reachable node to query the cluster
    first_node=$(find_reachable_node) || die "No Proxmox nodes reachable"

    ssh root@"${first_node}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .node // empty'
}

# Find the first reachable Proxmox node
find_reachable_node() {
    local i node
    for i in 1 2 3 4 5 6 7 8 9; do
        node="tappaas${i}"
        if ping -c 1 -W 1 "${node}.${MGMT}.internal" &>/dev/null; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

# Check if a node is reachable via SSH
check_node_reachable() {
    local node="$1"
    ssh -o ConnectTimeout=5 -o BatchMode=yes \
        "root@${node}.${MGMT}.internal" "true" &>/dev/null
}

# Attempt live migration of a VM.
# Returns 0 on success, 1 on failure.
try_live_migration() {
    local vmid="$1"
    local source_node="$2"
    local target_node="$3"

    info "  Attempting live migration of VMID ${vmid}: ${BL}${source_node}${CL} → ${BL}${target_node}${CL}"

    # Check if VM is managed by HA — if so, must remove from HA first
    # to avoid HA intercepting the migrate command
    local ha_managed=false
    local ha_state=""
    ha_state=$(ssh root@"${source_node}.${MGMT}.internal" \
        "ha-manager status 2>/dev/null" | grep "vm:${vmid}" | awk '{print $3}' || true)

    if [[ -n "${ha_state}" ]]; then
        ha_managed=true
        info "  VM is HA-managed (state: ${ha_state}) — temporarily removing from HA"
        save_ha_state "${vmid}" "${source_node}"
        remove_ha "${vmid}" "${source_node}"
        sleep 2
    fi

    local migrate_result=0
    ssh root@"${source_node}.${MGMT}.internal" \
        "qm migrate ${vmid} ${target_node} --online 1 --with-local-disks 1" 2>&1 \
        || migrate_result=$?

    if [[ ${migrate_result} -eq 0 ]]; then
        info "  ${GN}✓${CL} Live migration succeeded"
        if [[ "${ha_managed}" == "true" ]]; then
            restore_ha "${vmid}" "${target_node}"
        fi
        return 0
    else
        warn "Live migration failed (exit code ${migrate_result})"
        # Re-add HA on source if we removed it (VM is still there)
        if [[ "${ha_managed}" == "true" ]]; then
            restore_ha "${vmid}" "${source_node}"
        fi
        return 1
    fi
}

# Perform offline migration (shutdown → migrate → start).
do_offline_migration() {
    local vmid="$1"
    local source_node="$2"
    local target_node="$3"
    local vmname="${4:-VM ${vmid}}"

    info "  Performing offline migration of ${BL}${vmname}${CL} (VMID ${vmid}): ${BL}${source_node}${CL} → ${BL}${target_node}${CL}"

    # Check if VM is managed by HA
    local ha_managed=false
    local ha_state=""
    ha_state=$(ssh root@"${source_node}.${MGMT}.internal" \
        "ha-manager status 2>/dev/null" | grep "vm:${vmid}" | awk '{print $3}' || true)

    if [[ -n "${ha_state}" ]]; then
        ha_managed=true
        save_ha_state "${vmid}" "${source_node}"

        # Use HA to stop the VM (avoids lock conflicts)
        info "  Stopping VM via HA manager..."
        ssh root@"${source_node}.${MGMT}.internal" \
            "ha-manager set vm:${vmid} --state stopped" 2>/dev/null || true

        # Wait for HA to stop the VM (query any reachable node via cluster API)
        local query_node
        query_node=$(find_reachable_node) || die "No Proxmox nodes reachable"
        local ha_retries=0
        while [[ ${ha_retries} -lt 30 ]]; do
            local vm_status
            vm_status=$(ssh root@"${query_node}.${MGMT}.internal" \
                "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
                | jq -r --argjson id "${vmid}" \
                    '.[] | select(.vmid == $id and .type == "qemu") | .status // empty' 2>/dev/null || true)
            if [[ "${vm_status}" == "stopped" ]]; then
                break
            fi
            sleep 3
            ha_retries=$((ha_retries + 1))
        done

        info "  Removing from HA..."
        remove_ha "${vmid}" "${source_node}"
        sleep 2
    else
        # Not HA-managed — shutdown directly
        info "  Shutting down VM ${vmid}..."
        local shutdown_ok=true
        ssh root@"${source_node}.${MGMT}.internal" \
            "qm shutdown ${vmid} --timeout 90" 2>&1 || shutdown_ok=false

        if [[ "${shutdown_ok}" == "false" ]]; then
            warn "Graceful shutdown failed — forcing stop"
            ssh root@"${source_node}.${MGMT}.internal" "qm stop ${vmid}" 2>&1 || true
        fi
    fi

    # Wait for VM to stop (use cluster API to avoid config-not-found errors)
    local query_node2
    query_node2=$(find_reachable_node) || die "No Proxmox nodes reachable"
    local retries=0
    while [[ ${retries} -lt 30 ]]; do
        local status
        status=$(ssh root@"${query_node2}.${MGMT}.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r --argjson id "${vmid}" \
                '.[] | select(.vmid == $id and .type == "qemu") | .status // empty' 2>/dev/null || true)
        if [[ "${status}" == "stopped" ]]; then
            break
        fi
        sleep 2
        retries=$((retries + 1))
    done

    local final_status
    final_status=$(ssh root@"${query_node2}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .status // empty' 2>/dev/null || true)
    if [[ "${final_status}" != "stopped" ]]; then
        die "VM ${vmid} did not stop within timeout (status: ${final_status:-unknown})"
    fi
    info "  VM stopped"

    # Migrate
    info "  Migrating VM ${vmid} to ${target_node}..."
    ssh root@"${source_node}.${MGMT}.internal" \
        "qm migrate ${vmid} ${target_node}" 2>&1 || die "Offline migration failed for VM ${vmid}"
    info "  ${GN}✓${CL} Migration completed"

    # Start on target
    info "  Starting VM ${vmid} on ${target_node}..."
    ssh root@"${target_node}.${MGMT}.internal" "qm start ${vmid}" 2>&1 || {
        die "Failed to start VM ${vmid} on ${target_node}"
    }
    info "  ${GN}✓${CL} VM started on ${target_node}"

    # Restore HA on target node
    if [[ "${ha_managed}" == "true" ]]; then
        restore_ha "${vmid}" "${target_node}"
    fi

    return 0
}

# Save HA state (resource + affinity rule) for a VM before removing it.
# Sets global variables: _HA_RULE_NAME, _HA_RULE_NODES
save_ha_state() {
    local vmid="$1"
    local any_node="$2"

    _HA_RULE_NAME=""
    _HA_RULE_NODES=""

    # Find any HA affinity rule that references this VM
    local rule_json
    rule_json=$(ssh root@"${any_node}.${MGMT}.internal" \
        "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null || echo "[]")

    _HA_RULE_NAME=$(echo "${rule_json}" | jq -r \
        --arg res "vm:${vmid}" \
        '.[] | select(.resources == $res and .type == "node-affinity") | .rule // empty' 2>/dev/null || true)

    if [[ -n "${_HA_RULE_NAME}" ]]; then
        _HA_RULE_NODES=$(echo "${rule_json}" | jq -r \
            --arg name "${_HA_RULE_NAME}" \
            '.[] | select(.rule == $name) | .nodes // empty' 2>/dev/null || true)
        info "  Saved HA rule: ${_HA_RULE_NAME} (nodes: ${_HA_RULE_NODES})"
    fi
}

# Remove HA resource and rule for a VM.
remove_ha() {
    local vmid="$1"
    local any_node="$2"

    # Remove affinity rule first (if saved)
    if [[ -n "${_HA_RULE_NAME}" ]]; then
        ssh root@"${any_node}.${MGMT}.internal" \
            "pvesh delete /cluster/ha/rules/${_HA_RULE_NAME}" 2>/dev/null || true
    fi

    # Remove HA resource
    ssh root@"${any_node}.${MGMT}.internal" \
        "ha-manager remove vm:${vmid}" 2>/dev/null || true
}

# Restore HA resource and affinity rule for a VM after migration.
restore_ha() {
    local vmid="$1"
    local node="$2"

    info "  Re-adding VM ${vmid} to HA on ${node}..."
    ssh root@"${node}.${MGMT}.internal" \
        "ha-manager add vm:${vmid} --state started" 2>/dev/null || {
        warn "Could not re-add VM ${vmid} to HA — please add manually"
        return
    }

    # Restore affinity rule if one was saved
    if [[ -n "${_HA_RULE_NAME}" && -n "${_HA_RULE_NODES}" ]]; then
        info "  Restoring HA rule: ${_HA_RULE_NAME} (nodes: ${_HA_RULE_NODES})"
        ssh root@"${node}.${MGMT}.internal" \
            "pvesh create /cluster/ha/rules --rule ${_HA_RULE_NAME} --type node-affinity --resources vm:${vmid} --nodes '${_HA_RULE_NODES}'" 2>/dev/null || {
            warn "Could not restore HA rule '${_HA_RULE_NAME}' — please recreate manually"
        }
    fi
}

# Migrate a single module by name.
# Determines source/target, attempts live then offline.
migrate_module() {
    local module="$1"
    local force_offline="${2:-false}"
    local module_json="${CONFIG_DIR}/${module}.json"

    if [[ ! -f "${module_json}" ]]; then
        die "Module config not found: ${module_json}"
    fi

    local vmid vmname ha_node config_node
    vmid=$(jq -r '.vmid // empty' "${module_json}")
    vmname=$(jq -r '.vmname // empty' "${module_json}")
    ha_node=$(jq -r '.HANode // empty' "${module_json}")
    config_node=$(jq -r '.node // empty' "${module_json}")

    if [[ -z "${vmid}" ]]; then
        die "Module '${module}' has no vmid configured"
    fi
    if [[ -z "${ha_node}" ]]; then
        die "Module '${module}' has no HANode configured — cannot determine migration target"
    fi

    vmname="${vmname:-${module}}"

    # Find where the VM is currently running
    local current_node
    current_node=$(get_vm_current_node "${vmid}")

    if [[ -z "${current_node}" ]]; then
        die "VM ${vmid} (${vmname}) is not running on any node"
    fi

    # Determine target: migrate to the HA node (the "other" node)
    local target_node
    if [[ "${current_node}" == "${ha_node}" ]]; then
        # VM is on its HA node — migrate back to its primary (config) node
        target_node="${config_node}"
        info "VM ${BL}${vmname}${CL} is on HA node ${BL}${ha_node}${CL} — migrating back to primary ${BL}${config_node}${CL}"
    elif [[ "${current_node}" == "${config_node}" ]]; then
        # VM is on its primary node — migrate to HA node
        target_node="${ha_node}"
        info "VM ${BL}${vmname}${CL} is on primary node ${BL}${config_node}${CL} — migrating to HA node ${BL}${ha_node}${CL}"
    else
        # VM is on some other node — migrate to config node
        target_node="${config_node}"
        info "VM ${BL}${vmname}${CL} is on ${BL}${current_node}${CL} — migrating to configured node ${BL}${config_node}${CL}"
    fi

    if [[ "${current_node}" == "${target_node}" ]]; then
        info "VM ${BL}${vmname}${CL} (VMID ${vmid}) is already on ${BL}${target_node}${CL} — nothing to do"
        return 0
    fi

    # Check target node is reachable
    if ! check_node_reachable "${target_node}"; then
        die "Target node ${target_node} is not reachable"
    fi

    echo ""
    info "${BOLD}Migrating ${BL}${vmname}${CL}${BOLD} (VMID ${vmid}): ${BL}${current_node}${CL} → ${BL}${target_node}${CL}${BOLD}${CL}"

    if [[ "${force_offline}" == "true" ]]; then
        info "  --offline flag set — skipping live migration attempt"
        do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"
    else
        # Try live migration first
        if try_live_migration "${vmid}" "${current_node}" "${target_node}"; then
            return 0
        fi

        echo ""
        info "  Falling back to offline migration..."
        do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"
    fi
}

# Migrate all VMs that belong on the given node back to it.
migrate_to_node() {
    local target_node="$1"
    local force_offline="${2:-false}"

    info "${BOLD}Migrating all VMs back to node: ${BL}${target_node}${CL}"
    echo ""

    if ! check_node_reachable "${target_node}"; then
        die "Target node ${target_node} is not reachable"
    fi

    # Find all modules whose configured 'node' matches the target
    local migrated=0
    local skipped=0
    local failed=0

    for module_json in "${CONFIG_DIR}"/*.json; do
        [[ -f "${module_json}" ]] || continue
        local basename
        basename=$(basename "${module_json}" .json)

        # Skip non-module configs (configuration.json, zones.json, etc.)
        local vmid
        vmid=$(jq -r '.vmid // empty' "${module_json}" 2>/dev/null)
        if [[ -z "${vmid}" ]]; then
            continue
        fi

        local config_node
        config_node=$(jq -r '.node // empty' "${module_json}" 2>/dev/null)

        if [[ "${config_node}" != "${target_node}" ]]; then
            continue
        fi

        # Check where the VM is actually running
        local current_node
        current_node=$(get_vm_current_node "${vmid}")

        if [[ -z "${current_node}" ]]; then
            warn "VM ${vmid} (${basename}) is not running — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "${current_node}" == "${target_node}" ]]; then
            info "  ${GN}✓${CL} ${basename} (VMID ${vmid}) — already on ${target_node}"
            skipped=$((skipped + 1))
            continue
        fi

        # This VM needs migration
        local vmname
        vmname=$(jq -r '.vmname // empty' "${module_json}" 2>/dev/null)
        vmname="${vmname:-${basename}}"

        echo ""
        info "${BOLD}Migrating ${BL}${vmname}${CL}${BOLD} (VMID ${vmid}): ${BL}${current_node}${CL} → ${BL}${target_node}${CL}${BOLD}${CL}"

        local migrate_ok=false
        if [[ "${force_offline}" == "true" ]]; then
            info "  --offline flag set — using offline migration"
            if do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"; then
                migrate_ok=true
            fi
        else
            if try_live_migration "${vmid}" "${current_node}" "${target_node}"; then
                migrate_ok=true
            else
                echo ""
                info "  Falling back to offline migration..."
                if do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"; then
                    migrate_ok=true
                fi
            fi
        fi

        if [[ "${migrate_ok}" == "true" ]]; then
            migrated=$((migrated + 1))
        else
            error "Failed to migrate ${vmname} (VMID ${vmid})"
            failed=$((failed + 1))
        fi
    done

    echo ""
    info "${BOLD}Migration summary for node ${BL}${target_node}${CL}:"
    info "  Migrated:  ${migrated}"
    info "  Skipped:   ${skipped}"
    if [[ ${failed} -gt 0 ]]; then
        error "  Failed:    ${failed}"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local mode=""            # "module" or "node"
    local target=""          # module name or node name
    local force_offline=false

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --node)
                if [[ -z "${2:-}" ]]; then
                    die "--node requires a node name argument"
                fi
                mode="node"
                target="$2"
                shift 2
                ;;
            --offline)
                force_offline=true
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "${mode}" ]]; then
                    die "Unexpected argument: $1"
                fi
                mode="module"
                target="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${mode}" || -z "${target}" ]]; then
        die "No module name or --node specified"
    fi

    # Validate dependencies
    command -v jq &>/dev/null || die "Required command 'jq' not found"
    command -v ssh &>/dev/null || die "Required command 'ssh' not found"

    echo ""
    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS VM Migration                        ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    case "${mode}" in
        module)
            migrate_module "${target}" "${force_offline}"
            ;;
        node)
            migrate_to_node "${target}" "${force_offline}"
            ;;
    esac

    echo ""
    info "${GN}${BOLD}Migration completed${CL}"
}

main "$@"
