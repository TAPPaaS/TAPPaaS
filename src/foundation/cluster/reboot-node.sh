#!/usr/bin/env bash
#
# TAPPaaS Cluster Node Reboot (reboot-node.sh)
#
# Performs a controlled Proxmox node reboot with HA drain and verification.
# Pattern: HA maintenance enable → wait for VM migration → reboot →
#          wait for node return → verify kernel → HA maintenance disable.
#
# This is a HITL (human-in-the-loop) operator script for rebooting ONE node.
# The shared reboot sequence lives in lib/reboot-node-lib.sh (reboot_one_node),
# which this script and the automated cluster orchestrator (reboot-cluster.sh)
# both use. cluster/update.sh emits a warn with the link to this script when a
# pending kernel reboot is detected.
#
# Usage:
#   reboot-node.sh --dry-run  <node>   # preview impact, no changes (default)
#   reboot-node.sh --execute  <node>   # execute after confirmation
#
# Guards:
#   - HA quorum check (≥2 active nodes required)
#   - Full impact preview before any action
#   - Operator must type the node name to confirm
#   - --execute flag required; dry-run is the default
#
# Examples:
#   reboot-node.sh --dry-run tappaas2
#   reboot-node.sh --execute tappaas2
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/reboot-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/reboot-node-lib.sh"

###############################################################################
# Args
###############################################################################
DRY_RUN=1
NODE=""

usage() {
    cat <<'EOF'
Usage: reboot-node.sh [--dry-run|--execute] <node>

  --dry-run   Preview impact without making changes (default)
  --execute   Execute the reboot after confirmation

Examples:
  reboot-node.sh --dry-run tappaas2
  reboot-node.sh --execute tappaas2
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --execute)  DRY_RUN=0; shift ;;
        --help|-h)  usage; exit 0 ;;
        -*)         die "Unknown option: $1" ;;
        *)          NODE="$1"; shift ;;
    esac
done

[[ -n "$NODE" ]] || { usage; die "Node name required"; }

###############################################################################
# Step 1: Pre-flight checks
###############################################################################
echo
info "${BOLD}TAPPaaS reboot-node — ${NODE}${CL}"
if [[ "$DRY_RUN" -eq 1 ]]; then
    info "  Mode: ${YW}DRY-RUN${CL} (no changes)"
else
    info "  Mode: ${GN}EXECUTE${CL}"
fi
echo

info "${BOLD}Step 1: Pre-flight checks${CL}"

# Connectivity
rn_node_ssh "$NODE" "true" || die "Cannot reach $(rn_node_fqdn "$NODE")"
info "  ${GN}✓${CL} ${NODE} is reachable"

# Kernel gap
RUNNING=$(rn_running_kernel "$NODE")
LATEST=$(rn_latest_kernel "$NODE")
info "  Running kernel : ${RUNNING}"
info "  Latest kernel  : ${LATEST}"
if ! rn_kernel_gap "$NODE"; then
    warn "  No kernel gap detected — reboot may not be necessary"
fi

# HA quorum: count alive cluster nodes (LRM active or idle), need >=2 so
# dropping this one keeps the cluster quorate.
ACTIVE_NODES=$(rn_ha_active_count "$NODE")
info "  Alive cluster nodes: ${ACTIVE_NODES}"
[[ "${ACTIVE_NODES:-0}" -ge 2 ]] || die "HA quorum check failed: fewer than 2 alive nodes. Aborting."
info "  ${GN}✓${CL} HA quorum OK"

###############################################################################
# Step 2: Impact preview
###############################################################################
echo
info "${BOLD}Step 2: Impact preview${CL}"

# HA-managed VMs on this node
HA_VMS=$(rn_ha_vms_on_node "$NODE")
info "  HA-managed VMs (will auto-migrate to other nodes):"
if [[ -n "$HA_VMS" ]]; then
    while IFS= read -r vm; do info "    ${GN}→${CL} ${vm}"; done <<< "$HA_VMS"
else
    info "    (none)"
fi

# Non-HA VMs on this node
ALL_VMS=$(rn_node_ssh "$NODE" "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\"{print \$1,\$2}'" || true)
ALL_LXCS=$(rn_node_ssh "$NODE" "pct list 2>/dev/null | awk 'NR>1 && \$2==\"running\"{print \$1,\$3}'" || true)
HA_IDS=$(echo "$HA_VMS" | grep -oP '\d+' | tr '\n' '|' | sed 's/|$//' || true)
NON_HA_VMS=""
if [[ -n "$ALL_VMS" ]]; then
    NON_HA_VMS=$(echo "$ALL_VMS" | grep -vE "^(${HA_IDS})[[:space:]]" || true)
fi
info "  Non-HA VMs + LXCs (will shut down — restart automatically on boot):"
if [[ -n "$NON_HA_VMS" ]]; then
    while IFS= read -r vm; do info "    ${YW}↓${CL} VM ${vm}"; done <<< "$NON_HA_VMS"
fi
if [[ -n "$ALL_LXCS" ]]; then
    while IFS= read -r lxc; do info "    ${YW}↓${CL} LXC ${lxc}"; done <<< "$ALL_LXCS"
fi
[[ -z "$NON_HA_VMS" && -z "$ALL_LXCS" ]] && info "    (none)"

echo
info "  Estimated downtime: ~3-5 minutes for ${NODE}"
info "  HA VMs experience brief migration (~30s); non-HA VMs experience full downtime"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    info "${YW}DRY-RUN complete — no changes made.${CL}"
    info "  To execute: reboot-node.sh --execute ${NODE}"
    exit 0
fi

###############################################################################
# Step 3: Confirmation (HITL guard)
###############################################################################
echo
warn "${BOLD}You are about to reboot ${NODE} in EXECUTE mode.${CL}"
warn "  This will cause downtime for non-HA workloads listed above."
read -rp "  Type the node name to confirm (or Ctrl-C to abort): " CONFIRM
[[ "$CONFIRM" == "$NODE" ]] || die "Confirmation mismatch — aborting"

###############################################################################
# Step 4: Controlled reboot (shared routine)
###############################################################################
echo
reboot_one_node "$NODE" || die "Reboot of ${NODE} failed"

echo
info "${BOLD}${GN}✓${CL} ${NODE} reboot complete.${BOLD} Verify HA status:${CL}"
info "  ha-manager status"
