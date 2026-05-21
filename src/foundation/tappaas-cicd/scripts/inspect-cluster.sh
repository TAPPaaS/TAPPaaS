#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Inspect Cluster
#
# Compares actual running VMs across the Proxmox cluster against the
# module configurations in ~/config. Flags:
#   - VMs running but not defined in any config
#   - Configured modules whose VMs are not running
#
# Usage: inspect-cluster.sh
#

set -euo pipefail

# ── Source common library ────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-install-routines.sh
source "${SCRIPT_DIR}/common-install-routines.sh"

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

info "${BOLD}TAPPaaS Cluster Inspection${CL}"
echo ""

# ── Discover cluster nodes ───────────────────────────────────────────

# Find reachable nodes from configuration.json (or fall back to scanning tappaas1..9)
NODES=()
CONFIG_NODES=$(get_all_node_hostnames 2>/dev/null || true)
if [[ -n "$CONFIG_NODES" ]]; then
    while IFS= read -r node; do
        local_dns=$(get_node_dns_hostname 0 2>/dev/null || echo "$node")
        # Use dns-hostname for FQDN lookup if available
        node_fqdn="${node}.${MGMT}.internal"
        if ping -c 1 -W 1 "${node_fqdn}" &>/dev/null; then
            NODES+=("${node}")
        fi
    done <<< "$CONFIG_NODES"
fi
# Fallback: scan tappaas1..9 if no nodes found from config
if [[ ${#NODES[@]} -eq 0 ]]; then
    for i in 1 2 3 4 5 6 7 8 9; do
        node="tappaas${i}"
        if ping -c 1 -W 1 "${node}.${MGMT}.internal" &>/dev/null; then
            NODES+=("${node}")
        fi
    done
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
    die "No Proxmox nodes reachable"
fi

info "  Reachable nodes: ${BL}${NODES[*]}${CL}"

# ── Collect running VMs from cluster ─────────────────────────────────

# Use pvesh on first reachable node to get cluster-wide VM list
FIRST_NODE="${NODES[0]}"
CLUSTER_VMS=$(ssh root@"${FIRST_NODE}.${MGMT}.internal" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null) \
    || die "Failed to query cluster resources"

# Build arrays of running guest info: vmid, name, node, status, type.
# Include both qemu VMs and lxc containers so cluster:lxc modules (issue #203)
# are not falsely reported as NOT RUNNING.
RUNNING_VMIDS=()
declare -A VM_NAME_MAP VM_NODE_MAP VM_STATUS_MAP VM_TYPE_MAP

while IFS= read -r line; do
    vmid=$(echo "${line}" | jq -r '.vmid')
    name=$(echo "${line}" | jq -r '.name // "unknown"')
    node=$(echo "${line}" | jq -r '.node // "unknown"')
    status=$(echo "${line}" | jq -r '.status // "unknown"')
    vmtype=$(echo "${line}" | jq -r '.type // "unknown"')

    [[ "${vmtype}" != "qemu" && "${vmtype}" != "lxc" ]] && continue

    RUNNING_VMIDS+=("${vmid}")
    VM_NAME_MAP["${vmid}"]="${name}"
    VM_NODE_MAP["${vmid}"]="${node}"
    VM_STATUS_MAP["${vmid}"]="${status}"
    VM_TYPE_MAP["${vmid}"]="${vmtype}"
done < <(echo "${CLUSTER_VMS}" | jq -c '.[]')

info "  Found ${BL}${#RUNNING_VMIDS[@]}${CL} guests (VMs + containers) in cluster"

# ── Collect configured modules ───────────────────────────────────────

CONFIG_VMIDS=()
declare -A CONFIG_MODULE_MAP CONFIG_NODE_MAP CONFIG_STATUS_MAP

for json_file in "${CONFIG_DIR}"/*.json; do
    [[ ! -f "${json_file}" ]] && continue
    basename_file=$(basename "${json_file}" .json)

    # Skip non-module configs (configuration.json, firewall.json, zones.json, etc.)
    vmid=$(jq -r '.vmid // empty' "${json_file}" 2>/dev/null)
    [[ -z "${vmid}" ]] && continue

    module_name="${basename_file}"
    node=$(jq -r ".node // \"$(get_node_hostname 0)\"" "${json_file}" 2>/dev/null)
    mstatus=$(jq -r '.status // empty' "${json_file}" 2>/dev/null)

    CONFIG_VMIDS+=("${vmid}")
    CONFIG_MODULE_MAP["${vmid}"]="${module_name}"
    CONFIG_NODE_MAP["${vmid}"]="${node}"
    CONFIG_STATUS_MAP["${vmid}"]="${mstatus}"
done

info "  Found ${BL}${#CONFIG_VMIDS[@]}${CL} configured modules with VMIDs"
echo ""

# ── Compare: running VMs table ───────────────────────────────────────

info "${BOLD}Cluster Guest Status:${CL}"
printf "  ${BOLD}%-8s  %-20s  %-12s  %-6s  %-10s  %-10s${CL}\n" "VMID" "Name" "Node" "Type" "Status" "Config"
printf "  %-8s  %-20s  %-12s  %-6s  %-10s  %-10s\n" "--------" "--------------------" "------------" "------" "----------" "----------"

WARNINGS=0

# Sort VMIDs numerically
SORTED_RUNNING=$(printf '%s\n' "${RUNNING_VMIDS[@]}" | sort -n)

while IFS= read -r vmid; do
    [[ -z "${vmid}" ]] && continue
    name="${VM_NAME_MAP[${vmid}]}"
    node="${VM_NODE_MAP[${vmid}]}"
    status="${VM_STATUS_MAP[${vmid}]}"
    gtype="${VM_TYPE_MAP[${vmid}]/qemu/vm}"

    if [[ -n "${CONFIG_MODULE_MAP[${vmid}]:-}" ]]; then
        # An external module (status=external, issue #216) is a known-but-
        # unmanaged guest — show [external] rather than a plain "yes".
        if [[ "${CONFIG_STATUS_MAP[${vmid}]:-}" == "external" ]]; then
            config_status="${BL}[external]${CL}"
        else
            config_status="${GN}yes${CL}"
        fi
    else
        config_status="${YW}NOT IN CONFIG${CL}"
        WARNINGS=$((WARNINGS + 1))
    fi

    printf "  %-8s  %-20s  %-12s  %-6s  %-10s  %b\n" "${vmid}" "${name}" "${node}" "${gtype}" "${status}" "${config_status}"
done <<< "${SORTED_RUNNING}"

echo ""

# ── Compare: configured modules not running ──────────────────────────
# Archived modules (status=archived, #215) and external guests (status=external,
# #216) are intentionally not TAPPaaS-running — report them informationally,
# not as a missing-VM error.

MISSING=0
ARCHIVED=0
EXTERNAL_DOWN=0

for vmid in "${CONFIG_VMIDS[@]}"; do
    found=false
    for running_vmid in "${RUNNING_VMIDS[@]}"; do
        if [[ "${vmid}" == "${running_vmid}" ]]; then
            found=true
            break
        fi
    done

    if [[ "${found}" == "false" ]]; then
        module="${CONFIG_MODULE_MAP[${vmid}]}"
        node="${CONFIG_NODE_MAP[${vmid}]}"
        case "${CONFIG_STATUS_MAP[${vmid}]:-}" in
            archived)
                ARCHIVED=$((ARCHIVED + 1))
                echo -e "  ${YW}VMID ${vmid}  ${module}  [archived]  — VM removed, config + backups retained${CL}" ;;
            external)
                EXTERNAL_DOWN=$((EXTERNAL_DOWN + 1))
                echo -e "  ${BL}VMID ${vmid}  ${module}  [external]  — externally managed, not currently running${CL}" ;;
            *)
                MISSING=$((MISSING + 1))
                echo -e "  ${RD}VMID ${vmid}  ${module}  (expected on ${node})  — NOT RUNNING${CL}" ;;
        esac
    fi
done

if [[ "${MISSING}" -eq 0 && "${ARCHIVED}" -eq 0 && "${EXTERNAL_DOWN}" -eq 0 ]]; then
    info "  All configured modules have running VMs"
elif [[ "${MISSING}" -eq 0 ]]; then
    info "  All managed configured modules have running VMs (${ARCHIVED} archived, ${EXTERNAL_DOWN} external down)"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────

if [[ "${WARNINGS}" -eq 0 && "${MISSING}" -eq 0 ]]; then
    info "${GN}Cluster inspection passed — no discrepancies found${CL}"
else
    if [[ "${WARNINGS}" -gt 0 ]]; then
        warn "${WARNINGS} VM(s) running without a TAPPaaS config"
    fi
    if [[ "${MISSING}" -gt 0 ]]; then
        error "${MISSING} configured module(s) not running"
    fi
fi
