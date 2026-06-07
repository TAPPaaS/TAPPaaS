#!/usr/bin/env bash
#
# TAPPaaS Cluster Reboot Orchestrator (reboot-cluster.sh) — issue #275
#
# Reboots every Proxmox cluster node that has a pending kernel upgrade, one node
# at a time, in a controlled sequence:
#
#   - enumerate nodes (configuration.json tappaas-nodes)
#   - keep only nodes whose running kernel is older than the newest installed one
#   - reboot the tappaas-cicd host LAST (HA live-migrates the cicd VM — and this
#     running orchestrator with it — off that node before it reboots, so the run
#     survives). Other nodes go first, in config order.
#   - before each node: re-assert HA quorum (>=2 active); reboot via the shared
#     reboot_one_node routine; verify the new kernel.
#   - ABORT the whole pass if any node fails to return (issue #275 requirement).
#
# Governed by tappaas.automaticReboot (configuration.json, default true). When
# false, this script only reports which nodes need a reboot and exits 0 — the
# operator performs them manually with reboot-node.sh.
#
# This is the automated counterpart to reboot-node.sh; both share
# lib/reboot-node-lib.sh. update-tappaas calls this as a final phase.
#
# Usage:
#   reboot-cluster.sh [--dry-run]    # preview the plan, no changes (default)
#   reboot-cluster.sh --execute      # perform the reboot pass
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

usage() {
    cat <<'EOF'
Usage: reboot-cluster.sh [--dry-run|--execute]

  --dry-run   Preview the reboot plan without making changes (default)
  --execute   Perform the reboot pass

Governed by tappaas.automaticReboot in configuration.json (default true).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --execute)  DRY_RUN=0; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          die "Unknown argument: $1" ;;
    esac
done

###############################################################################
# Resolve cluster topology
###############################################################################
echo
info "${BOLD}TAPPaaS reboot-cluster${CL}"
if [[ "$DRY_RUN" -eq 1 ]]; then
    info "  Mode: ${YW}DRY-RUN${CL} (no changes)"
else
    info "  Mode: ${GN}EXECUTE${CL}"
fi

# All cluster nodes, in configuration order (tappaas1 first).
mapfile -t ALL_NODES < <(get_all_node_hostnames)
[[ "${#ALL_NODES[@]}" -gt 0 ]] || die "No cluster nodes found in configuration.json"

# Entry node used for cluster-wide queries (first reachable configured node).
ENTRY=""
for n in "${ALL_NODES[@]}"; do
    if rn_node_ssh "$n" "true" 2>/dev/null; then ENTRY="$n"; break; fi
done
[[ -n "$ENTRY" ]] || die "No cluster node is reachable over SSH"

# Which node currently hosts the tappaas-cicd VM (this orchestrator runs inside
# it). That node is rebooted LAST so HA live-migration keeps this run alive.
CICD_VMID=$(jq -r '.vmid // 130' "${CONFIG_DIR}/tappaas-cicd.json" 2>/dev/null || echo 130)
CICD_HOST=$(rn_node_ssh "$ENTRY" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null \
    | jq -r --argjson id "$CICD_VMID" '.[] | select(.vmid==$id) | .node' 2>/dev/null | head -1 || true)
[[ -n "$CICD_HOST" ]] || warn "Could not determine the tappaas-cicd (vm:${CICD_VMID}) host node"
info "  tappaas-cicd (vm:${CICD_VMID}) host: ${BL}${CICD_HOST:-unknown}${CL} (rebooted last)"

###############################################################################
# Determine which nodes need a reboot, and the order
###############################################################################
info "${BOLD}Checking kernel gaps${CL}"
GAP_OTHERS=()   # gapped nodes that are NOT the cicd host
GAP_CICD=""     # the cicd host, if it has a gap
for n in "${ALL_NODES[@]}"; do
    if ! rn_node_ssh "$n" "true" 2>/dev/null; then
        warn "  ${n}: unreachable — skipping"
        continue
    fi
    if rn_kernel_gap "$n"; then
        running=$(rn_running_kernel "$n"); latest=$(rn_latest_kernel "$n")
        info "  ${YW}↻${CL} ${n}: ${running} running, ${latest} installed — reboot needed"
        if [[ -n "$CICD_HOST" && "$n" == "$CICD_HOST" ]]; then
            GAP_CICD="$n"
        else
            GAP_OTHERS+=("$n")
        fi
    else
        info "  ${GN}✓${CL} ${n}: up to date"
    fi
done

# Final order: other gapped nodes (config order) first, cicd host last.
ORDER=("${GAP_OTHERS[@]}")
[[ -n "$GAP_CICD" ]] && ORDER+=("$GAP_CICD")

if [[ "${#ORDER[@]}" -eq 0 ]]; then
    info "${GN}✓${CL} No nodes need a reboot."
    exit 0
fi

info "${BOLD}Reboot order:${CL} ${ORDER[*]}"

###############################################################################
# Policy gate
###############################################################################
if ! automatic_reboot_enabled; then
    warn "${BOLD}automaticReboot=false${CL} — ${#ORDER[@]} node(s) need a reboot but will NOT be rebooted automatically:"
    for n in "${ORDER[@]}"; do
        warn "    ${n}  →  reboot-node.sh --execute ${n}"
    done
    exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    info "${YW}DRY-RUN complete — no changes made.${CL}"
    info "  To execute: reboot-cluster.sh --execute"
    exit 0
fi

###############################################################################
# Execute — one node at a time, abort on first failure
###############################################################################
echo
info "${BOLD}Starting controlled reboot pass (${#ORDER[@]} node(s))${CL}"
done_count=0
for n in "${ORDER[@]}"; do
    echo
    if ! reboot_one_node "$n"; then
        die "Reboot of ${n} failed — aborting further reboots (${done_count}/${#ORDER[@]} completed). Cluster left quorate; investigate ${n} before continuing."
    fi
    done_count=$((done_count + 1))
done

echo
info "${BOLD}${GN}✓${CL} Cluster reboot pass complete: ${done_count}/${#ORDER[@]} node(s) rebooted.${CL}"
