#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Inspect VM
#
# Generates a 3-column comparison table for a module's VM showing:
#   1. Released (Git) — from the source module JSON (in git repo)
#   2. Desired (~/config) — from ~/config/<module>.json (deployed config)
#   3. Actual value   — from the running VM via Proxmox API
#
# Color coding:
#   Yellow — config value differs from git value (config drift)
#   Red    — actual value differs from config value (VM drift)
#
# Usage: inspect-vm.sh <module-name>
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# Network helpers (vmnet_parse / vmnet_resolve_trunks / vmnet_zone_vlantag) —
# the same zone→VLAN and trunk-resolution logic cluster:vm uses to build NICs,
# so the Actual column matches how the live VM was provisioned. (issue #334)
# shellcheck source=../../cluster/lib/vm-net.sh disable=SC1091
. /home/tappaas/TAPPaaS/src/foundation/cluster/lib/vm-net.sh

# ── Arguments ────────────────────────────────────────────────────────

if [[ -z "${1:-}" || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: inspect-vm.sh <module-name>"
    echo "Compares config, git, and actual VM values for a module."
    exit 0
fi

MODULE="$1"

# CONFIG_DIR provided by common-install-routines.sh
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly MGMT="mgmt"

# ── Validate module config ───────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON} — is '${MODULE}' installed?"
fi

VMID=$(get_config_value 'vmid' '')
NODE=$(get_config_value 'node' 'tappaas1')
VMNAME=$(get_config_value 'vmname' '')
[[ -z "${VMNAME}" ]] && VMNAME="${MODULE}"

if [[ -z "${VMID}" ]]; then
    die "No vmid defined in ${MODULE_JSON}"
fi

NODE_FQDN="${NODE}.${MGMT}.internal"

# ── Locate git source JSON ───────────────────────────────────────────

LOCATION=$(get_config_value 'location' '')
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
    # Normalize Pattern A → flat so .<key> resolves the same regardless of on-disk shape.
    normalize_module_config < "${MODULE_JSON}" 2>/dev/null | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

get_git() {
    if [[ -n "${GIT_JSON}" ]]; then
        normalize_module_config < "${GIT_JSON}" 2>/dev/null | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
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
        "${git_color}" "${git_val:--}" "${CL}" \
        "${cfg_color}" "${config_val:--}" "${CL}" \
        "${act_color}" "${actual_val:--}" "${CL}"
}

# ── Helper: format a VLAN tag for display ────────────────────────────
# Proxmox tag=0 means untagged — identical to carrying no tag at all. Collapse
# 0, "", and a missing tag all to "(untagged)" so they read as the same value
# and never show up as spurious drift. (issue #334)
fmt_vlan() {
    local t="$1"
    if [[ -z "${t}" || "${t}" == "0" ]]; then
        echo -n "(untagged)"
    else
        echo -n "${t}"
    fi
}

# ── Helper: normalize a ';'-separated VLAN list ──────────────────────
# Sort numerically and drop blanks so a resolved-config trunk list and the live
# trunk list compare equal regardless of ordering. (issue #334)
norm_trunks() {
    echo "$1" | tr ';' '\n' | sed '/^$/d' | sort -n | tr '\n' ';' | sed 's/;$//'
}

# ── Helper: print the comparison rows for one NIC (net0 / net1) ───────
# TAPPaaS VMs carry at most two NICs. For each we surface bridge, zone (by name
# AND by VLAN tag — two views of the same thing), the trunk allow-list resolved
# to VLAN tags, and the MAC. trunks0 on the firewall is normally the sentinel
# "ALL"; vmnet_resolve_trunks expands it to every active zone's tag exactly as
# cluster:vm does, so a missing-trunk mismatch shows as red drift. (issue #334)
print_nic() {
    local i="$1"
    local actual_net="${ACTUAL[net${i}]:-}"

    local config_bridge git_bridge config_zone git_zone
    local config_trunks git_trunks config_mac git_mac
    config_bridge=$(get_cfg "bridge${i}")
    git_bridge=$(get_git "bridge${i}")
    config_zone=$(get_cfg "zone${i}")
    git_zone=$(get_git "zone${i}")
    config_trunks=$(get_cfg "trunks${i}")
    git_trunks=$(get_git "trunks${i}")
    config_mac=$(get_cfg "mac${i}")
    git_mac=$(get_git "mac${i}")

    # NIC absent from config, git, AND the live VM → single "none" line. (#334)
    if [[ -z "${actual_net}" && -z "${config_bridge}" && -z "${git_bridge}" ]]; then
        printf "  %-18s  %-20s  %-20s  %-20s\n" "nic${i}" "none" "none" "none"
        return
    fi

    # Bridge
    print_row "bridge${i}" "${config_bridge}" "${git_bridge}" "$(vmnet_parse "${actual_net}" bridge)"

    # Zone shown two ways. The (tag) row carries the zone NAME and catches a
    # config-vs-git name change; the (vlan) row carries the VLAN NUMBER and
    # catches actual-vs-config drift — same split as before, just relabelled so
    # both views are clearly the same zone expressed differently. (#334)
    local actual_tag config_vlan
    actual_tag=$(vmnet_parse "${actual_net}" tag)
    config_vlan=""
    [[ -n "${config_zone}" ]] && config_vlan=$(vmnet_zone_vlantag "${config_zone}" "${zones_file}" 2>/dev/null || true)
    print_row "zone${i} (tag)"  "${config_zone}" "${git_zone}" "${config_zone}"
    print_row "zone${i} (vlan)" "$(fmt_vlan "${config_vlan}")" "$(fmt_vlan "${config_vlan}")" "$(fmt_vlan "${actual_tag}")"

    # Trunks — resolve the zone-name/sentinel config form to VLAN tags so it
    # lines up with the live list, and normalize ordering on both sides. (#334)
    local config_trunks_v git_trunks_v actual_trunks_v
    config_trunks_v=$(norm_trunks "$(vmnet_resolve_trunks "${config_trunks}" "${zones_file}" 2>/dev/null || true)")
    git_trunks_v=$(norm_trunks "$(vmnet_resolve_trunks "${git_trunks}" "${zones_file}" 2>/dev/null || true)")
    actual_trunks_v=$(norm_trunks "$(vmnet_parse "${actual_net}" trunks)")
    print_row "trunks${i}" "${config_trunks_v}" "${git_trunks_v}" "${actual_trunks_v}"

    # MAC
    print_row "mac${i}" "${config_mac}" "${git_mac}" "$(vmnet_parse "${actual_net}" mac)"
}

# ── Print table header ───────────────────────────────────────────────

printf "  ${BOLD}%-18s  %-20s  %-20s  %-20s${CL}\n" "Field" "Released (Git)" "Desired (~/config)" "Actual"
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

# Network — net0 and net1 (TAPPaaS allows at most two NICs per VM). Each NIC's
# bridge, zone (name + VLAN), trunks, and MAC are surfaced so an access-VLAN or
# trunk-allowlist mismatch is visible without raw `qm config`. (issue #334)
zones_file="${CONFIG_DIR}/zones.json"
print_nic 0
print_nic 1

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
    "${git_desc:--}" "${CL}" \
    "$( [[ -n "${git_desc}" && "${config_desc}" != "${git_desc}" ]] && echo -n "${YW}" || echo -n "${CL}" )" \
    "${config_desc:--}" "${CL}" \
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
