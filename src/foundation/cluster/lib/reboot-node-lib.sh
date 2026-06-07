#!/usr/bin/env bash
# shellcheck shell=bash
#
# reboot-node-lib.sh — shared per-node Proxmox reboot routine (issue #275).
#
# Sourced by both reboot-node.sh (HITL single node) and reboot-cluster.sh
# (automated multi-node orchestrator) so the controlled-reboot sequence lives in
# exactly one place:
#
#   quorum check -> HA maintenance enable -> wait for VM drain -> reboot ->
#   wait for node return -> verify kernel -> HA maintenance disable.
#
# Sourced AFTER common-install-routines.sh (needs info/warn/die + colours).
# Every function is node-parameterised (no global node state) so a caller can
# iterate over several nodes in one process.

MGMT_SUFFIX=".mgmt.internal"

# FQDN of a node on the management network.
rn_node_fqdn() { echo "${1}${MGMT_SUFFIX}"; }

# Run a command on a node over SSH (batch mode, short connect timeout).
rn_node_ssh() {
    local node="$1"; shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$(rn_node_fqdn "$node")" "$@"
}

# Block until a node answers SSH again, returning non-zero after <max> seconds.
# Default max is RN_WAIT_MAX (180s in production; lowered by tests).
rn_wait_for_node() {
    local node="$1" max="${2:-${RN_WAIT_MAX:-180}}" n=0
    info "  Waiting for ${node} to return..."
    until ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "$node")" "true" 2>/dev/null; do
        sleep 5; (( n+=5 ))
        [[ $n -lt $max ]] || return 1
    done
    return 0
}

# Currently-running kernel on a node.
rn_running_kernel() { rn_node_ssh "$1" "uname -r" 2>/dev/null || true; }

# Newest installed pve-kernel package version on a node (without the +pmx suffix).
rn_latest_kernel() {
    rn_node_ssh "$1" \
        "dpkg -l 'pve-kernel-*' 2>/dev/null | awk '/^ii/{print \$3}' | sort -V | tail -1 | sed 's/+.*//'" \
        2>/dev/null || true
}

# Return 0 when a node is running an older kernel than the newest installed one.
rn_kernel_gap() {
    local node="$1" running latest
    running=$(rn_running_kernel "$node")
    latest=$(rn_latest_kernel "$node")
    [[ -n "$running" && -n "$latest" && "$running" != *"$latest"* ]]
}

# Number of HA nodes whose local resource manager is active (proxy for quorum).
rn_ha_active_count() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep -c "lrm .* (active" || true
}

# Names of HA-managed VMs currently started on a node.
rn_ha_vms_on_node() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep "service vm:" | grep "${node}" | awk '{print $2}' || true
}

# Perform a controlled reboot of a single node. Returns 0 on success; non-zero
# on any failure (caller decides whether to abort the run). Assumes the caller
# has already confirmed/authorised the action.
#
# Arguments: <node>
reboot_one_node() {
    local node="$1"
    local latest active local_wait=0 new_running

    info "${BOLD}Rebooting ${node}${CL}"

    # Reachability.
    rn_node_ssh "$node" "true" 2>/dev/null || { error "Cannot reach ${node}"; return 1; }

    # Quorum: need >=2 active HA nodes so the cluster stays quorate and VMs can
    # migrate off this one.
    active=$(rn_ha_active_count "$node")
    if [[ "${active:-0}" -lt 2 ]]; then
        error "Quorum check failed for ${node}: only ${active:-0} active HA node(s) (need >=2)"
        return 1
    fi
    info "  ${GN}✓${CL} HA quorum OK (${active} active)"

    latest=$(rn_latest_kernel "$node")

    # HA maintenance mode → migrate managed VMs off this node.
    info "  Enabling HA maintenance mode..."
    rn_node_ssh "$node" "ha-manager crm-command node-maintenance enable ${node}" \
        || { error "Failed to enable HA maintenance mode on ${node}"; return 1; }

    while rn_node_ssh "$node" "ha-manager status 2>/dev/null" | grep "service vm:" | grep -q "${node}.*started"; do
        sleep 5; (( local_wait+=5 ))
        if [[ $local_wait -ge 120 ]]; then
            error "HA migration timeout on ${node} after 120s"
            return 1
        fi
    done
    info "  ${GN}✓${CL} HA VMs migrated off ${node}"

    # Reboot — the SSH connection drops, which is expected.
    info "  Issuing reboot..."
    rn_node_ssh "$node" "reboot" || true
    sleep 15
    if ! rn_wait_for_node "$node"; then
        error "Node ${node} did not return after reboot (left in maintenance mode so HA keeps its VMs elsewhere)"
        return 1
    fi
    info "  ${GN}✓${CL} ${node} is back online"

    # Verify the new kernel is the one actually running.
    new_running=$(rn_running_kernel "$node")
    if [[ -n "$latest" && "$new_running" == *"$latest"* ]]; then
        info "  ${GN}✓${CL} New kernel active: ${new_running}"
    else
        warn "  ${node} running ${new_running} (expected ${latest}) — check grub default"
    fi

    # Leave maintenance mode → HA migrates VMs back.
    info "  Disabling HA maintenance mode..."
    rn_node_ssh "$node" "ha-manager crm-command node-maintenance disable ${node}" \
        || warn "Failed to disable maintenance mode on ${node} — run manually: ha-manager crm-command node-maintenance disable ${node}"

    info "  ${GN}✓${CL} ${node} reboot complete"
    return 0
}
