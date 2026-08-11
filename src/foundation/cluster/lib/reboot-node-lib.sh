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

# Directory holding this library, so sibling module scripts (../cloudinit-orphans.sh)
# resolve regardless of the caller's cwd.
RN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# FQDN of a node on the management network.
rn_node_fqdn() { echo "${1}${MGMT_SUFFIX}"; }

# Run a command on a node over SSH (batch mode, short connect timeout).
# -n: never read local stdin — these are command-only calls, and consuming stdin
# would steal a caller's interactive confirmation (e.g. reboot-node.sh's prompt).
rn_node_ssh() {
    local node="$1"; shift
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$(rn_node_fqdn "$node")" "$@"
}

# Block until a node answers SSH again, returning non-zero after <max> seconds.
# Default max is RN_WAIT_MAX (180s in production; lowered by tests).
rn_wait_for_node() {
    local node="$1" max="${2:-${RN_WAIT_MAX:-180}}" n=0
    info "  Waiting for ${node} to return..."
    until ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "$node")" "true" 2>/dev/null; do
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

# Number of cluster nodes whose HA local resource manager is ALIVE — i.e. LRM
# state 'active' (currently managing services) OR 'idle' (up, but no HA services
# assigned to it right now). Both mean the node is online and quorate; only
# dead/stale LRMs are excluded. Used as the quorum guard: >=2 alive nodes means
# dropping one still leaves the cluster quorate.
#
# NB: counting only '(active' false-negatives a perfectly healthy cluster — a
# node with no HA services shows '(idle', so on a cluster where all guests
# happen to sit on one node the others read as "not active" and a reboot is
# wrongly refused. (Surfaced while validating #275/#308.)
rn_ha_active_count() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep -cE "lrm .* \((active|idle)" || true
}

# Names of HA-managed VMs currently started on a node.
rn_ha_vms_on_node() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep "service vm:" | grep "${node}" | awk '{print $2}' || true
}

# Free cloud-init volumes stranded on a node that has just rebooted (#146).
#
# A completed migration removes its own source copy, so the drain at the start
# of reboot_one_node leaves nothing behind. But if the node was fenced — or the
# drain aborted partway — a `vm-<id>-cloudinit` volume survives here, and it
# will abort every failback attempt with "volume already exists", leaving the
# CRM to retry every ~10s indefinitely. Sweep before leaving maintenance mode,
# while no HA service is trying to move onto this node yet.
#
# Non-fatal: a failed sweep must not abort an otherwise healthy reboot.
rn_sweep_cloudinit_orphans() {
    local node="$1"
    local sweep="${RN_LIB_DIR}/../cloudinit-orphans.sh"

    if [[ ! -x "$sweep" ]]; then
        debug "  cloudinit-orphans.sh not found — skipping stale-volume sweep"
        return 0
    fi

    info "  Sweeping stale cloud-init volumes on ${node}..."
    # --quiet keeps routine "nothing found" chatter out of the reboot log; any
    # volume actually freed is still reported by the sweep itself.
    if "$sweep" --execute --quiet "$node"; then
        info "  ${GN}✓${CL} Cloud-init sweep clean on ${node}"
    else
        # rc 1 = sweep error, rc 2 cannot occur with --execute.
        warn "  Stale cloud-init sweep on ${node} reported problems — check before relying on failback"
    fi
    return 0
}

# HA service states that are stable resting places; anything else means the CRM
# is still working. Kept in sync with health-manager/check-ha-health.sh.
RN_STEADY_STATES="started stopped disabled ignored freeze"

# Block until no HA service is in a transitional state, or <max> seconds pass.
# Returns non-zero on timeout, echoing the offending services.
rn_wait_ha_settled() {
    local node="$1" max="${2:-${RN_HA_SETTLE_MAX:-180}}" n=0 stuck
    while :; do
        stuck=$(rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
            | sed -n 's/^service \([^ ]*\) (\([^,]*\), \([^)]*\))$/\1 \3/p' \
            | while read -r sid state; do
                  [[ " ${RN_STEADY_STATES} " == *" ${state} "* ]] || echo "${sid}=${state}"
              done)
        [[ -n "$stuck" ]] || return 0
        [[ $n -lt $max ]] || { echo "$stuck"; return 1; }
        sleep 5; (( n+=5 ))
    done
}

# Perform a controlled reboot of a single node. Returns 0 on success; non-zero
# on any failure (caller decides whether to abort the run). Assumes the caller
# has already confirmed/authorised the action.
#
# Arguments: <node>
reboot_one_node() {
    local node="$1"
    local latest active local_wait=0 new_running stuck

    info "${BOLD}Rebooting ${node}${CL}"

    # Reachability.
    rn_node_ssh "$node" "true" 2>/dev/null || { error "Cannot reach ${node}"; return 1; }

    # Quorum: need >=2 active HA nodes so the cluster stays quorate and VMs can
    # migrate off this one.
    active=$(rn_ha_active_count "$node")
    if [[ "${active:-0}" -lt 2 ]]; then
        error "Quorum check failed for ${node}: only ${active:-0} alive cluster node(s) (need >=2)"
        return 1
    fi
    info "  ${GN}✓${CL} HA quorum OK (${active} alive)"

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
    if [[ -z "$latest" ]]; then
        info "  ${GN}✓${CL} Running kernel: ${new_running} (no newer kernel pending)"
    elif [[ "$new_running" == *"$latest"* ]]; then
        info "  ${GN}✓${CL} New kernel active: ${new_running}"
    else
        warn "  ${node} running ${new_running} (expected ${latest}) — check grub default"
    fi

    # Clear any cloud-init volume stranded here, so failback cannot wedge (#146).
    rn_sweep_cloudinit_orphans "$node"

    # Leave maintenance mode → HA migrates VMs back.
    info "  Disabling HA maintenance mode..."
    rn_node_ssh "$node" "ha-manager crm-command node-maintenance disable ${node}" \
        || warn "Failed to disable maintenance mode on ${node} — run manually: ha-manager crm-command node-maintenance disable ${node}"

    # Verify the failback actually converged. Without this the reboot reports
    # success while the CRM retries a failing migration forever (#146) — which
    # is exactly how a 27-hour retry loop went unnoticed.
    info "  Waiting for HA to settle..."
    if stuck=$(rn_wait_ha_settled "$node"); then
        info "  ${GN}✓${CL} HA settled — no services in transition"
    else
        warn "  HA did not settle after ${RN_HA_SETTLE_MAX:-180}s; still in transition:"
        while IFS= read -r _svc; do
            [[ -n "$_svc" ]] && warn "      ${_svc}"
        done <<< "${stuck}"
        warn "  Check for a stale cloud-init volume blocking migration:"
        warn "    ${RN_LIB_DIR}/../cloudinit-orphans.sh"
    fi

    info "  ${GN}✓${CL} ${node} reboot complete"
    return 0
}
