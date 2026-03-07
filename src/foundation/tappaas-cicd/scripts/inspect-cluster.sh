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

# Find reachable nodes by checking tappaas1..tappaas9
NODES=()
for i in 1 2 3 4 5 6 7 8 9; do
    node="tappaas${i}"
    if ping -c 1 -W 1 "${node}.${MGMT}.internal" &>/dev/null; then
        NODES+=("${node}")
    fi
done

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

# Build arrays of running VM info: vmid, name, node, status
# Filter to qemu VMs only (exclude LXC containers)
RUNNING_VMIDS=()
declare -A VM_NAME_MAP VM_NODE_MAP VM_STATUS_MAP

while IFS= read -r line; do
    vmid=$(echo "${line}" | jq -r '.vmid')
    name=$(echo "${line}" | jq -r '.name // "unknown"')
    node=$(echo "${line}" | jq -r '.node // "unknown"')
    status=$(echo "${line}" | jq -r '.status // "unknown"')
    vmtype=$(echo "${line}" | jq -r '.type // "unknown"')

    [[ "${vmtype}" != "qemu" ]] && continue

    RUNNING_VMIDS+=("${vmid}")
    VM_NAME_MAP["${vmid}"]="${name}"
    VM_NODE_MAP["${vmid}"]="${node}"
    VM_STATUS_MAP["${vmid}"]="${status}"
done < <(echo "${CLUSTER_VMS}" | jq -c '.[]')

info "  Found ${BL}${#RUNNING_VMIDS[@]}${CL} QEMU VMs in cluster"

# ── Collect configured modules ───────────────────────────────────────

CONFIG_VMIDS=()
declare -A CONFIG_MODULE_MAP CONFIG_NODE_MAP

for json_file in "${CONFIG_DIR}"/*.json; do
    [[ ! -f "${json_file}" ]] && continue
    basename_file=$(basename "${json_file}" .json)

    # Skip non-module configs (configuration.json, firewall.json, zones.json, etc.)
    vmid=$(jq -r '.vmid // empty' "${json_file}" 2>/dev/null)
    [[ -z "${vmid}" ]] && continue

    module_name="${basename_file}"
    node=$(jq -r '.node // "tappaas1"' "${json_file}" 2>/dev/null)

    CONFIG_VMIDS+=("${vmid}")
    CONFIG_MODULE_MAP["${vmid}"]="${module_name}"
    CONFIG_NODE_MAP["${vmid}"]="${node}"
done

info "  Found ${BL}${#CONFIG_VMIDS[@]}${CL} configured modules with VMIDs"
echo ""

# ── Compare: running VMs table ───────────────────────────────────────

info "${BOLD}Cluster VM Status:${CL}"
printf "  ${BOLD}%-8s  %-20s  %-12s  %-10s  %-10s${CL}\n" "VMID" "Name" "Node" "Status" "Config"
printf "  %-8s  %-20s  %-12s  %-10s  %-10s\n" "--------" "--------------------" "------------" "----------" "----------"

WARNINGS=0

# Sort VMIDs numerically
SORTED_RUNNING=$(printf '%s\n' "${RUNNING_VMIDS[@]}" | sort -n)

while IFS= read -r vmid; do
    [[ -z "${vmid}" ]] && continue
    name="${VM_NAME_MAP[${vmid}]}"
    node="${VM_NODE_MAP[${vmid}]}"
    status="${VM_STATUS_MAP[${vmid}]}"

    if [[ -n "${CONFIG_MODULE_MAP[${vmid}]:-}" ]]; then
        config_status="${GN}yes${CL}"
    else
        config_status="${YW}NOT IN CONFIG${CL}"
        WARNINGS=$((WARNINGS + 1))
    fi

    printf "  %-8s  %-20s  %-12s  %-10s  %b\n" "${vmid}" "${name}" "${node}" "${status}" "${config_status}"
done <<< "${SORTED_RUNNING}"

echo ""

# ── Compare: configured modules not running ──────────────────────────

MISSING=0
MISSING_LIST=""

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
        MISSING=$((MISSING + 1))
        MISSING_LIST="${MISSING_LIST}  ${RD}%-8s  %-20s  %-12s  NOT RUNNING${CL}\n"
        # Can't use printf with color in the accumulated string cleanly, so print inline
        echo -e "  ${RD}VMID ${vmid}  ${module}  (expected on ${node})  — NOT RUNNING${CL}"
    fi
done

if [[ "${MISSING}" -eq 0 ]]; then
    info "  All configured modules have running VMs"
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
