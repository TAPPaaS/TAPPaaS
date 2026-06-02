#!/usr/bin/env bash
#
# TAPPaaS Cluster Node Reboot (reboot-node.sh)
#
# Performs a controlled Proxmox node reboot with HA drain and verification.
# Pattern: HA maintenance enable → wait for VM migration → reboot →
#          wait for node return → verify kernel → HA maintenance disable.
#
# This is a HITL (human-in-the-loop) operator script. It is never called
# from update.sh or any automation. update.sh emits a warn with the link
# to this script when a pending kernel reboot is detected.
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

NODE_FQDN="${NODE}.mgmt.internal"
MGMT_SUFFIX=".mgmt.internal"

###############################################################################
# Helpers
###############################################################################
node_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 root@"${NODE_FQDN}" "$@"; }

wait_for_node() {
    local max=120 n=0
    info "  Waiting for ${NODE} to return..."
    until ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${NODE_FQDN}" "true" 2>/dev/null; do
        sleep 5; (( n+=5 ))
        [[ $n -lt $max ]] || die "Node ${NODE} did not return after ${max}s"
    done
}

###############################################################################
# Step 1: Pre-flight checks
###############################################################################
echo
info "${BOLD}TAPPaaS reboot-node — ${NODE}${CL}"
[[ "$DRY_RUN" -eq 1 ]] && info "  Mode: ${YW}DRY-RUN${CL} (no changes)" \
                        || info "  Mode: ${GN}EXECUTE${CL}"
echo

info "${BOLD}Step 1: Pre-flight checks${CL}"

# Connectivity
node_ssh "true" || die "Cannot reach ${NODE_FQDN}"
info "  ${GN}✓${CL} ${NODE} is reachable"

# Kernel gap
RUNNING=$(node_ssh "uname -r")
LATEST=$(node_ssh "dpkg -l 'pve-kernel-*' 2>/dev/null | awk '/^ii/{print \$3}' | sort -V | tail -1 | sed 's/+.*//'")
info "  Running kernel : ${RUNNING}"
info "  Latest kernel  : ${LATEST}"
if [[ "$RUNNING" == *"$LATEST"* ]]; then
    warn "  No kernel gap detected — reboot may not be necessary"
fi

# HA quorum
HA_STATUS=$(node_ssh "ha-manager status 2>/dev/null" || true)
ACTIVE_NODES=$(echo "$HA_STATUS" | grep -c "lrm .* (active" || true)
info "  HA active nodes: ${ACTIVE_NODES}"
[[ "${ACTIVE_NODES:-0}" -ge 2 ]] || die "HA quorum check failed: fewer than 2 active nodes. Aborting."
info "  ${GN}✓${CL} HA quorum OK"

###############################################################################
# Step 2: Impact preview
###############################################################################
echo
info "${BOLD}Step 2: Impact preview${CL}"

# HA-managed VMs on this node
HA_VMS=$(echo "$HA_STATUS" | grep "service vm:" | grep "${NODE}" | awk '{print $2}' || true)
info "  HA-managed VMs (will auto-migrate to other nodes):"
if [[ -n "$HA_VMS" ]]; then
    while IFS= read -r vm; do info "    ${GN}→${CL} ${vm}"; done <<< "$HA_VMS"
else
    info "    (none)"
fi

# Non-HA VMs on this node
ALL_VMS=$(node_ssh "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\"{print \$1,\$2}'" || true)
ALL_LXCS=$(node_ssh "pct list 2>/dev/null | awk 'NR>1 && \$2==\"running\"{print \$1,\$3}'" || true)
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
# Step 4: HA maintenance mode — migrate managed VMs
###############################################################################
echo
info "${BOLD}Step 3: Enable HA maintenance mode${CL}"
node_ssh "ha-manager crm-command node-maintenance enable ${NODE}" \
    || die "Failed to enable HA maintenance mode"
info "  ${GN}✓${CL} Maintenance mode enabled — waiting for VM migration..."

# Poll until all HA VMs have left this node
local_wait=0
while node_ssh "ha-manager status 2>/dev/null" | grep "service vm:" | grep -q "${NODE}.*started"; do
    sleep 5; (( local_wait+=5 ))
    [[ $local_wait -lt 120 ]] || die "HA migration timeout after 120s"
done
info "  ${GN}✓${CL} All HA VMs migrated off ${NODE}"

###############################################################################
# Step 5: Reboot
###############################################################################
echo
info "${BOLD}Step 4: Rebooting ${NODE}${CL}"
node_ssh "reboot" || true   # connection drops — expected
info "  Reboot initiated. Waiting for node to return..."
sleep 15
wait_for_node
info "  ${GN}✓${CL} ${NODE} is back online"

###############################################################################
# Step 6: Verify kernel
###############################################################################
echo
info "${BOLD}Step 5: Verify kernel${CL}"
NEW_RUNNING=$(node_ssh "uname -r")
info "  Running kernel: ${NEW_RUNNING}"
if [[ "$NEW_RUNNING" == *"$LATEST"* ]]; then
    info "  ${GN}✓${CL} New kernel active: ${NEW_RUNNING}"
else
    warn "  Kernel still ${NEW_RUNNING} (expected ${LATEST}) — check grub default"
fi

###############################################################################
# Step 7: Remove maintenance mode
###############################################################################
echo
info "${BOLD}Step 6: Remove HA maintenance mode${CL}"
node_ssh "ha-manager crm-command node-maintenance disable ${NODE}" \
    || warn "Failed to disable maintenance mode — do manually: ha-manager crm-command node-maintenance disable ${NODE}"
info "  ${GN}✓${CL} Maintenance mode removed — HA will migrate VMs back"

echo
info "${BOLD}${GN}✓${CL} ${NODE} reboot complete.${BOLD} Verify HA status:${CL}"
info "  ha-manager status"
if [[ "$NEW_RUNNING" != *"$LATEST"* ]]; then
    warn "  Kernel mismatch — manual intervention may be required"
fi
