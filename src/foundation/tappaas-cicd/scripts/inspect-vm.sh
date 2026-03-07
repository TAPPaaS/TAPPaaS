#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Inspect VM
#
# Generates a 3-column comparison table for a module's VM showing:
#   1. Config value  — from ~/config/<module>.json (deployed config)
#   2. Git value     — from the source module JSON (in git repo)
#   3. Actual value  — from the running VM via Proxmox API
#
# Color coding:
#   Yellow — config value differs from git value (config drift)
#   Red    — actual value differs from config value (VM drift)
#
# Usage: inspect-vm.sh <module-name>
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

# ── Arguments ────────────────────────────────────────────────────────

if [[ -z "${1:-}" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: inspect-vm.sh <module-name>"
    echo "Compares config, git, and actual VM values for a module."
    exit 0
fi

MODULE="$1"

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly MGMT="mgmt"

# ── Validate module config ───────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON} — is '${MODULE}' installed?"
fi

VMID=$(jq -r '.vmid // empty' "${MODULE_JSON}")
NODE=$(jq -r '.node // "tappaas1"' "${MODULE_JSON}")
VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
[[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"

if [[ -z "${VMID}" ]]; then
    die "No vmid defined in ${MODULE_JSON}"
fi

NODE_FQDN="${NODE}.${MGMT}.internal"

# ── Locate git source JSON ───────────────────────────────────────────

LOCATION=$(jq -r '.location // empty' "${MODULE_JSON}")
GIT_JSON=""

if [[ -n "${LOCATION}" && -f "${LOCATION}/${MODULE}.json" ]]; then
    GIT_JSON="${LOCATION}/${MODULE}.json"
elif [[ -n "${LOCATION}" && -f "${LOCATION}/${VMNAME}.json" ]]; then
    GIT_JSON="${LOCATION}/${VMNAME}.json"
fi

if [[ -z "${GIT_JSON}" ]]; then
    warn "Git source JSON not found (location: ${LOCATION:-not set})"
    warn "Git column will show 'N/A'"
fi

info "${BOLD}TAPPaaS VM Inspection: ${BL}${VMNAME}${CL} (VMID: ${VMID}) on ${NODE}"
echo ""

# ── Get actual VM config from Proxmox ────────────────────────────────

ACTUAL_CONFIG=$(ssh -o ConnectTimeout=5 root@"${NODE_FQDN}" \
    "qm config ${VMID}" 2>/dev/null) \
    || die "Failed to get VM config from Proxmox (VMID: ${VMID} on ${NODE})"

# Parse actual values into associative array
declare -A ACTUAL
while IFS=': ' read -r key value; do
    [[ -z "${key}" ]] && continue
    ACTUAL["${key}"]="${value}"
done <<< "${ACTUAL_CONFIG}"

# Also get VM status for running state
VM_STATUS=$(ssh root@"${NODE_FQDN}" "qm status ${VMID}" 2>/dev/null | awk '{print $2}') || VM_STATUS="unknown"

# Get actual node where VM is currently running (may differ from config if migrated)
ACTUAL_NODE=$(ssh root@"${NODE_FQDN}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid == $id) | .node // empty') || ACTUAL_NODE=""

# ── Helper: get config value ─────────────────────────────────────────

get_cfg() {
    jq -r --arg k "$1" '.[$k] // empty' "${MODULE_JSON}" 2>/dev/null
}

get_git() {
    if [[ -n "${GIT_JSON}" ]]; then
        jq -r --arg k "$1" '.[$k] // empty' "${GIT_JSON}" 2>/dev/null
    fi
}

# ── Helper: format comparison row ────────────────────────────────────

WARNINGS=0
ERRORS=0

print_row() {
    local field="$1"
    local config_val="$2"
    local git_val="$3"
    local actual_val="$4"

    # Determine colors
    local cfg_color="${CL}"
    local git_color="${CL}"
    local act_color="${CL}"

    # Yellow: config differs from git
    if [[ -n "${git_val}" && "${config_val}" != "${git_val}" ]]; then
        cfg_color="${YW}"
        git_color="${YW}"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Red: actual differs from config (only when both have values)
    if [[ -n "${actual_val}" && -n "${config_val}" && "${config_val}" != "-" && "${actual_val}" != "${config_val}" ]]; then
        act_color="${RD}"
        cfg_color="${RD}"
        ERRORS=$((ERRORS + 1))
    fi

    printf "  %-18s  %b%-20s%b  %b%-20s%b  %b%-20s%b\n" \
        "${field}" \
        "${cfg_color}" "${config_val:--}" "${CL}" \
        "${git_color}" "${git_val:--}" "${CL}" \
        "${act_color}" "${actual_val:--}" "${CL}"
}

# ── Print table header ───────────────────────────────────────────────

printf "  ${BOLD}%-18s  %-20s  %-20s  %-20s${CL}\n" "Field" "Config" "Git" "Actual"
printf "  %-18s  %-20s  %-20s  %-20s\n" "------------------" "--------------------" "--------------------" "--------------------"

# ── Compare fields ───────────────────────────────────────────────────

# VM identity
print_row "vmname" "$(get_cfg vmname)" "$(get_git vmname)" "${ACTUAL[name]:-}"
print_row "vmid" "$(get_cfg vmid)" "$(get_git vmid)" "${VMID}"
print_row "node" "$(get_cfg node)" "$(get_git node)" "${ACTUAL_NODE}"
print_row "status" "-" "-" "${VM_STATUS}"

# CPU
config_cores=$(get_cfg cores)
git_cores=$(get_git cores)
print_row "cores" "${config_cores}" "${git_cores}" "${ACTUAL[cores]:-}"

# Memory
config_mem=$(get_cfg memory)
git_mem=$(get_git memory)
print_row "memory" "${config_mem}" "${git_mem}" "${ACTUAL[memory]:-}"

# Storage / disk
config_disk=$(get_cfg diskSize)
git_disk=$(get_git diskSize)
# Actual disk size from qm config (e.g., "tanka1:vm-311-disk-0,size=32G")
actual_disk=""
for key in scsi0 virtio0 ide0 sata0; do
    if [[ -n "${ACTUAL[${key}]:-}" ]]; then
        actual_disk=$(echo "${ACTUAL[${key}]}" | grep -oP 'size=\K[^,]+' || true)
        break
    fi
done
print_row "diskSize" "${config_disk}" "${git_disk}" "${actual_disk}"

config_storage=$(get_cfg storage)
git_storage=$(get_git storage)
print_row "storage" "${config_storage}" "${git_storage}" ""

# BIOS
config_bios=$(get_cfg bios)
git_bios=$(get_git bios)
print_row "bios" "${config_bios}" "${git_bios}" "${ACTUAL[bios]:-seabios}"

# CPU type
config_cpu=$(get_cfg cputype)
git_cpu=$(get_git cputype)
print_row "cputype" "${config_cpu}" "${git_cpu}" "${ACTUAL[cpu]:-}"

# Network
config_bridge=$(get_cfg bridge0)
git_bridge=$(get_git bridge0)
actual_net0="${ACTUAL[net0]:-}"
actual_bridge=$(echo "${actual_net0}" | grep -oP 'bridge=\K[^,]+' || true)
print_row "bridge0" "${config_bridge}" "${git_bridge}" "${actual_bridge}"

config_zone=$(get_cfg zone0)
git_zone=$(get_git zone0)
actual_tag=$(echo "${actual_net0}" | grep -oP 'tag=\K[^,]+' || true)
# Resolve zone name to VLAN tag for comparison display
zones_file="${CONFIG_DIR}/zones.json"
config_vlan=""
if [[ -n "${config_zone}" && -f "${zones_file}" ]]; then
    config_vlan=$(jq -r --arg z "${config_zone}" '.[$z].vlantag // empty' "${zones_file}" 2>/dev/null)
fi
print_row "zone0" "${config_zone}" "${git_zone}" "${config_zone}"
print_row "zone0 (vlan)" "${config_vlan:-N/A}" "${config_vlan:-N/A}" "${actual_tag:-(untagged)}"

# MAC address
config_mac=$(get_cfg mac0)
git_mac=$(get_git mac0)
actual_mac=$(echo "${actual_net0}" | grep -oiP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' || true)
print_row "mac0" "${config_mac}" "${git_mac}" "${actual_mac}"

# HA
config_ha=$(get_cfg HANode)
git_ha=$(get_git HANode)
print_row "HANode" "${config_ha}" "${git_ha}" ""

# Description — Proxmox wraps in HTML, not directly comparable
config_desc=$(get_cfg description)
git_desc=$(get_git description)
# Only compare config vs git, show actual as info-only
printf "  %-18s  %b%-20s%b  %b%-20s%b  %-20s\n" \
    "description" \
    "$( [[ -n "${git_desc}" && "${config_desc}" != "${git_desc}" ]] && echo -n "${YW}" || echo -n "${CL}" )" \
    "${config_desc:--}" "${CL}" \
    "$( [[ -n "${git_desc}" && "${config_desc}" != "${git_desc}" ]] && echo -n "${YW}" || echo -n "${CL}" )" \
    "${git_desc:--}" "${CL}" \
    "(see Proxmox UI)"
if [[ -n "${git_desc}" && "${config_desc}" != "${git_desc}" ]]; then
    WARNINGS=$((WARNINGS + 1))
fi

# Tags — Proxmox stores tags as semicolon-separated lowercase sorted
config_tag=$(get_cfg vmtag)
git_tag=$(get_git vmtag)
actual_tags="${ACTUAL[tags]:-}"
# Normalize both to sorted semicolon-separated lowercase for comparison
normalize_tags() { echo "$1" | tr ',;' '\n' | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ';' | sed 's/;$//'; }
config_tag_norm=$(normalize_tags "${config_tag}")
actual_tag_norm=$(normalize_tags "${actual_tags}")
if [[ -n "${config_tag}" && -n "${actual_tags}" && "${config_tag_norm}" == "${actual_tag_norm}" ]]; then
    print_row "vmtag" "${config_tag}" "${git_tag}" "${config_tag}"
else
    print_row "vmtag" "${config_tag}" "${git_tag}" "${actual_tags}"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────

if [[ "${WARNINGS}" -eq 0 && "${ERRORS}" -eq 0 ]]; then
    info "${GN}VM inspection passed — no discrepancies found${CL}"
else
    if [[ "${WARNINGS}" -gt 0 ]]; then
        warn "${WARNINGS} field(s) differ between config and git (${YW}yellow${CL})"
    fi
    if [[ "${ERRORS}" -gt 0 ]]; then
        error "${ERRORS} field(s) differ between config and actual VM (${RD}red${CL})"
    fi
fi
