#!/usr/bin/env bash
#
# TAPPaaS Cluster Node Migration
#
# Evacuate all VMs from a node (for maintenance), return them afterwards,
# or list what would be migrated.
#
# Usage:
#   migrate-node.sh <node-name>                   Evacuate all VMs from <node>
#   migrate-node.sh --return <node-name>           Return all VMs that belong on <node>
#   migrate-node.sh --list <node-name>             List VMs and planned actions (dry run)
#
# Options:
#   --offline       Skip live migration attempts; use offline migration
#   -h, --help      Show this help message
#
# Examples:
#   migrate-node.sh --list tappaas1               # Show what would happen
#   migrate-node.sh tappaas1                      # Evacuate tappaas1 for maintenance
#   migrate-node.sh --return tappaas1             # Bring all VMs back after maintenance
#   migrate-node.sh --offline tappaas1            # Evacuate using offline migration only
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

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: migrate-node.sh <node-name>
       migrate-node.sh --return <node-name>
       migrate-node.sh --list <node-name>

Evacuate or return VMs on a Proxmox cluster node.

Modes:
    <node-name>               Evacuate: migrate all VMs OFF this node
    --return <node-name>      Return: bring back VMs that belong on this node
    --list <node-name>        List: show planned actions without migrating

Options:
    --offline                 Skip live migration; use offline migration only
    -h, --help                Show this help message

Examples:
    migrate-node.sh --list tappaas1           # Dry run — show what would happen
    migrate-node.sh tappaas1                  # Evacuate tappaas1 for maintenance
    migrate-node.sh --return tappaas1         # Return all VMs after maintenance
    migrate-node.sh --offline tappaas1        # Evacuate with offline migration only
EOF
}

# ── Helper functions ─────────────────────────────────────────────────

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

# Get all running QEMU VMs from the cluster as JSON
# Output: JSON array with vmid, name, node, status
get_cluster_vms() {
    local query_node="$1"
    ssh root@"${query_node}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null
}

# Build a list of module configs that have a vmid.
# Output: tab-separated lines of "module_name\tvmid\tconfig_node\tha_node\tvmname"
get_module_configs() {
    for module_json in "${CONFIG_DIR}"/*.json; do
        [[ -f "${module_json}" ]] || continue
        local basename
        basename=$(basename "${module_json}" .json)

        local vmid config_node ha_node vmname
        vmid=$(jq -r '.vmid // empty' "${module_json}" 2>/dev/null)
        [[ -n "${vmid}" ]] || continue

        config_node=$(jq -r '.node // empty' "${module_json}" 2>/dev/null)
        ha_node=$(jq -r '.HANode // empty' "${module_json}" 2>/dev/null)
        vmname=$(jq -r '.vmname // empty' "${module_json}" 2>/dev/null)
        vmname="${vmname:-${basename}}"

        printf '%s|%s|%s|%s|%s\n' "${basename}" "${vmid}" "${config_node:-NONE}" "${ha_node:-NONE}" "${vmname}"
    done
}

# ── List mode ────────────────────────────────────────────────────────

do_list() {
    local target_node="$1"
    local mode="$2"  # "evacuate" or "return"

    local query_node
    query_node=$(find_reachable_node) || die "No Proxmox nodes reachable"

    local cluster_vms
    cluster_vms=$(get_cluster_vms "${query_node}")

    info "${BOLD}Node: ${BL}${target_node}${CL}"
    if [[ "${mode}" == "evacuate" ]]; then
        info "Mode: Evacuate — VMs currently on ${BL}${target_node}${CL} that would be migrated away"
    else
        info "Mode: Return — VMs that belong on ${BL}${target_node}${CL} but are elsewhere"
    fi
    echo ""

    printf "  ${BOLD}%-20s %-8s %-14s %-14s %-10s${CL}\n" "MODULE" "VMID" "CURRENT NODE" "TARGET" "ACTION"
    printf "  %-20s %-8s %-14s %-14s %-10s\n" "────────────────────" "────────" "──────────────" "──────────────" "──────────"

    local count=0

    while IFS='|' read -r module vmid config_node ha_node vmname; do
        # Find where this VM is actually running
        local current_node
        current_node=$(echo "${cluster_vms}" | jq -r \
            --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .node // empty' 2>/dev/null)

        if [[ -z "${current_node}" ]]; then
            # VM not running
            if [[ "${mode}" == "return" && "${config_node}" == "${target_node}" ]]; then
                printf "  ${YW}%-20s %-8s %-14s %-14s %-10s${CL}\n" \
                    "${vmname}" "${vmid}" "(not running)" "${target_node}" "SKIPPED"
            fi
            continue
        fi

        if [[ "${mode}" == "evacuate" ]]; then
            # Show VMs currently ON this node
            if [[ "${current_node}" == "${target_node}" ]]; then
                # Determine where it would go
                local migrate_to=""
                if [[ -n "${ha_node}" && "${ha_node}" != "NONE" ]]; then
                    migrate_to="${ha_node}"
                else
                    migrate_to="(no HANode)"
                fi

                if [[ "${migrate_to}" == "(no HANode)" ]]; then
                    printf "  ${YW}%-20s %-8s %-14s %-14s %-10s${CL}\n" \
                        "${vmname}" "${vmid}" "${current_node}" "${migrate_to}" "NO TARGET"
                else
                    printf "  ${GN}%-20s %-8s %-14s %-14s %-10s${CL}\n" \
                        "${vmname}" "${vmid}" "${current_node}" "${migrate_to}" "MIGRATE"
                    count=$((count + 1))
                fi
            fi
        else
            # Return mode: show VMs that belong on target_node but are elsewhere
            if [[ "${config_node}" == "${target_node}" && "${current_node}" != "${target_node}" ]]; then
                printf "  ${GN}%-20s %-8s %-14s %-14s %-10s${CL}\n" \
                    "${vmname}" "${vmid}" "${current_node}" "${target_node}" "RETURN"
                count=$((count + 1))
            elif [[ "${config_node}" == "${target_node}" && "${current_node}" == "${target_node}" ]]; then
                printf "  %-20s %-8s %-14s %-14s %-10s\n" \
                    "${vmname}" "${vmid}" "${current_node}" "—" "ALREADY HOME"
            fi
        fi
    done < <(get_module_configs)

    echo ""
    if [[ ${count} -gt 0 ]]; then
        info "${count} VM(s) would be migrated"
    else
        info "No VMs to migrate"
    fi
}

# ── Evacuate mode ────────────────────────────────────────────────────

do_evacuate() {
    local target_node="$1"
    local force_offline="$2"

    local query_node
    query_node=$(find_reachable_node) || die "No Proxmox nodes reachable"

    local cluster_vms
    cluster_vms=$(get_cluster_vms "${query_node}")

    info "${BOLD}Evacuating node: ${BL}${target_node}${CL}"
    info "All VMs on ${BL}${target_node}${CL} will be migrated to their HA nodes"
    echo ""

    local migrated=0
    local skipped=0
    local failed=0
    local offline_flag=""
    if [[ "${force_offline}" == "true" ]]; then
        offline_flag="--offline"
    fi

    # Collect VMs to migrate first, then migrate
    local -a to_migrate=()

    while IFS='|' read -r module vmid config_node ha_node vmname; do
        local current_node
        current_node=$(echo "${cluster_vms}" | jq -r \
            --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .node // empty' 2>/dev/null)

        if [[ -z "${current_node}" || "${current_node}" != "${target_node}" ]]; then
            continue
        fi

        if [[ -z "${ha_node}" || "${ha_node}" == "NONE" ]]; then
            warn "${vmname} (VMID ${vmid}) has no HANode configured — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        to_migrate+=("${module}")
    done < <(get_module_configs)

    if [[ ${#to_migrate[@]} -eq 0 ]]; then
        info "No VMs to evacuate from ${target_node}"
        return 0
    fi

    info "VMs to migrate: ${#to_migrate[@]}"
    echo ""

    for module in "${to_migrate[@]}"; do
        if /home/tappaas/bin/migrate-vm.sh ${offline_flag} "${module}"; then
            migrated=$((migrated + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done

    echo ""
    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  Evacuation Summary: ${BL}${target_node}${CL}${BOLD}                    ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"
    info "  Migrated:  ${GN}${migrated}${CL}"
    info "  Skipped:   ${skipped}"
    if [[ ${failed} -gt 0 ]]; then
        error "  Failed:    ${failed}"
        return 1
    fi
}

# ── Return mode ──────────────────────────────────────────────────────

do_return() {
    local target_node="$1"
    local force_offline="$2"

    local query_node
    query_node=$(find_reachable_node) || die "No Proxmox nodes reachable"

    # Check target node is reachable
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
        "root@${target_node}.${MGMT}.internal" "true" &>/dev/null; then
        die "Target node ${target_node} is not reachable — cannot return VMs"
    fi

    local cluster_vms
    cluster_vms=$(get_cluster_vms "${query_node}")

    info "${BOLD}Returning VMs to node: ${BL}${target_node}${CL}"
    info "VMs configured for ${BL}${target_node}${CL} that are elsewhere will be migrated back"
    echo ""

    local migrated=0
    local skipped=0
    local failed=0
    local offline_flag=""
    if [[ "${force_offline}" == "true" ]]; then
        offline_flag="--offline"
    fi

    # Collect VMs to return
    local -a to_return=()

    while IFS='|' read -r module vmid config_node ha_node vmname; do
        if [[ "${config_node}" != "${target_node}" ]]; then
            continue
        fi

        local current_node
        current_node=$(echo "${cluster_vms}" | jq -r \
            --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .node // empty' 2>/dev/null)

        if [[ -z "${current_node}" ]]; then
            warn "${vmname} (VMID ${vmid}) is not running — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "${current_node}" == "${target_node}" ]]; then
            info "  ${GN}✓${CL} ${vmname} (VMID ${vmid}) — already on ${target_node}"
            skipped=$((skipped + 1))
            continue
        fi

        to_return+=("${module}")
    done < <(get_module_configs)

    if [[ ${#to_return[@]} -eq 0 ]]; then
        info "No VMs to return to ${target_node}"
        return 0
    fi

    info "VMs to return: ${#to_return[@]}"
    echo ""

    for module in "${to_return[@]}"; do
        # migrate-vm.sh detects the VM is away from its primary node and returns it
        if /home/tappaas/bin/migrate-vm.sh ${offline_flag} "${module}"; then
            migrated=$((migrated + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done

    echo ""
    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  Return Summary: ${BL}${target_node}${CL}${BOLD}                        ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"
    info "  Returned:  ${GN}${migrated}${CL}"
    info "  Skipped:   ${skipped}"
    if [[ ${failed} -gt 0 ]]; then
        error "  Failed:    ${failed}"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local mode=""            # "evacuate", "return", or "list"
    local node=""
    local force_offline=false

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
            --list)
                mode="list"
                shift
                ;;
            --return)
                mode="return"
                shift
                ;;
            --offline)
                force_offline=true
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "${node}" ]]; then
                    die "Unexpected argument: $1"
                fi
                node="$1"
                shift
                ;;
        esac
    done

    # Default mode is evacuate
    if [[ -z "${mode}" ]]; then
        mode="evacuate"
    fi

    if [[ -z "${node}" ]]; then
        die "No node name specified"
    fi

    # Validate dependencies
    command -v jq &>/dev/null || die "Required command 'jq' not found"
    command -v ssh &>/dev/null || die "Required command 'ssh' not found"

    echo ""
    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Node Migration                      ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"
    echo ""

    case "${mode}" in
        list)
            # If --list is combined with --return, show return view; otherwise show evacuate view
            # We detect by checking if --return was also specified. For simplicity,
            # --list always shows both views.
            do_list "${node}" "evacuate"
            echo ""
            info "───────────────────────────────────────────────"
            echo ""
            do_list "${node}" "return"
            ;;
        evacuate)
            do_evacuate "${node}" "${force_offline}"
            ;;
        return)
            do_return "${node}" "${force_offline}"
            ;;
    esac
}

main "$@"
