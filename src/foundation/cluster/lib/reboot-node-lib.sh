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

# The one `ha-manager status` parser (#434). This file grew two of its own — a
# sed for the settle check and a grep|grep|awk for the per-node list — alongside
# copies in snapshot-vm and migrate-vm that disagreed with both. Falls back to
# the repo copy on a system that has not re-run pre-update.sh since it landed.
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
else
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . "${RN_LIB_DIR}/../../tappaas-cicd/lib/ha-vm-lib.sh"
fi

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
# Default max is RN_WAIT_MAX (600s in production; lowered by tests). A server
# can spend two minutes in firmware before its kernel starts; the wait polls, so
# a fast node still returns as soon as it is back.
#
# With <old-boot-id>, the node counts as back only once it reports a DIFFERENT
# boot id. A node that has been told to reboot but has not finished shutting
# down yet still answers SSH, so without this check the first probe succeeds and
# the caller declares the node back — then reads the PRE-reboot kernel and warns
# about the boot loader while the node is only just going down. Omitting the
# argument keeps the old behaviour (any SSH answer means back).
rn_wait_for_node() {
    local node="$1" max="${2:-${RN_WAIT_MAX:-600}}" old_boot_id="${3:-}" n=0 boot_id
    info "  Waiting for ${node} to return..."
    while :; do
        boot_id=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "$node")" \
            "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
        if [[ -n "$boot_id" && "$boot_id" != "$old_boot_id" ]]; then
            return 0
        fi
        sleep 5; (( n+=5 ))
        [[ $n -lt $max ]] || return 1
    done
}

# True once <node> is a functioning CLUSTER MEMBER again, not merely reachable.
#
# rn_wait_for_node returns as soon as sshd answers with a new boot id, but sshd
# starts early in boot while pve-cluster (pmxcfs), corosync and pve-ha-lrm come
# up seconds later. `ha-manager` reads cluster state from /etc/pve, so any call
# made in that window fails with:
#
#   no such cluster node '<node>'
#
# which is precisely how tappaas1 was left in maintenance mode for 13 hours on
# 2026-08-25: the disable fired 3.4s before the node rejoined corosync, the
# failure was only warned about, and the run reported reboot=ok. Same class as
# #468 (sshd answering treated as readiness) one layer up, at node scope.
#
# The node's own LRM appearing in `ha-manager status` is the precondition for
# the very command we are about to run, so it is what we test.
rn_node_is_cluster_member() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep -qE "^lrm ${node} "
}

# True while <node>'s LRM reports maintenance mode.
rn_node_in_maintenance() {
    local node="$1"
    rn_node_ssh "$node" "ha-manager status 2>/dev/null" 2>/dev/null \
        | grep -qE "^lrm ${node} \(maintenance"
}

# Block until <node> is a cluster member again. Non-zero on timeout.
rn_wait_cluster_member() {
    local node="$1" max="${2:-${RN_CLUSTER_WAIT_MAX:-300}}" n=0
    info "  Waiting for ${node} to rejoin the cluster..."
    while :; do
        rn_node_is_cluster_member "$node" && return 0
        [[ $n -lt $max ]] || return 1
        sleep 5; (( n+=5 ))
    done
}

# Clear maintenance mode and CONFIRM it actually cleared.
#
# Two failure modes are covered. The command can be rejected outright (the race
# above), and it can be accepted while the CRM has not yet applied it — the flag
# clears a cycle or two later, so a bare exit status proves nothing. Re-issue
# the command up to <tries> times, polling the flag between attempts.
rn_disable_maintenance() {
    local node="$1" tries="${2:-${RN_MAINT_DISABLE_TRIES:-3}}" i n out
    for (( i=1; i<=tries; i++ )); do
        out="$(rn_node_ssh "$node" "ha-manager crm-command node-maintenance disable ${node}" 2>&1)" || true
        [[ -n "${out}" ]] && debug "    disable attempt ${i}/${tries}: ${out}"
        for (( n=0; n<4; n++ )); do
            rn_node_in_maintenance "$node" || return 0
            sleep 5
        done
    done
    return 1
}

# Currently-running kernel on a node.
rn_running_kernel() { rn_node_ssh "$1" "uname -r" 2>/dev/null || true; }

# Newest installed kernel on a node, in `uname -r` form (e.g. 7.0.14-12-pve).
#
# Read from the installed kernel PACKAGE NAMES, not their version fields:
#   - the package prefix changed from pve-kernel-* to proxmox-kernel-*, so both
#     are matched; querying only the old prefix returned nothing and silently
#     disabled the whole reboot pass.
#   - proxmox-kernel-helper carries an unrelated version (9.2.0), so the version
#     column cannot be sorted on.
#   - the -signed suffix is stripped so the result compares directly to uname -r.
rn_latest_kernel() {
    rn_node_ssh "$1" \
        "dpkg -l 'proxmox-kernel-*' 'pve-kernel-*' 2>/dev/null | awk '/^ii/ && \$2 ~ /^(proxmox|pve)-kernel-[0-9]/ {v=\$2; sub(/^(proxmox|pve)-kernel-/, \"\", v); sub(/-signed\$/, \"\", v); print v}' | sort -V | tail -1" \
        2>/dev/null || true
}

# Return 0 when a node is running an older kernel than the newest installed one.
rn_kernel_gap() {
    local node="$1" running latest
    running=$(rn_running_kernel "$node")
    latest=$(rn_latest_kernel "$node")
    # Both values are in uname -r form, so compare them exactly.
    [[ -n "$running" && -n "$latest" && "$running" != "$latest" ]]
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

# Names of HA-managed VMs currently on a node.
#
# Restricted to `vm:` service ids, as it always has been — HA-managed containers
# (`ct:`) are not listed here, and reboot-node.sh's impact preview accounts for
# them under its separate `pct list` section.
rn_ha_vms_on_node() {
    local node="$1"
    havm_ha_services_on_node "$(rn_node_fqdn "$node")" "$node" 2>/dev/null \
        | awk '$1 ~ /^vm:/ { print $1 }' || true
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

# Block until no HA service is in a transitional state, or <max> seconds pass.
# Returns non-zero on timeout, echoing the offending services.
#
# The steady-state list and the parsing both live in ha-vm-lib now
# (HAVM_STEADY_STATES / havm_ha_unsettled); this is the retry loop around them.
rn_wait_ha_settled() {
    local node="$1" max="${2:-${RN_HA_SETTLE_MAX:-180}}" n=0 stuck
    while :; do
        stuck=$(havm_ha_unsettled "$(rn_node_fqdn "$node")" 2>/dev/null || true)
        [[ -n "$stuck" ]] || return 0
        [[ $n -lt $max ]] || { echo "$stuck"; return 1; }
        sleep 5; (( n+=5 ))
    done
}

# HA services still on <node> that a reboot would kill: every state except the
# ones with nothing running. `migrate` and `relocate` count — the guest is still
# here until the CRM moves the service's node field (2026-10-08: draining on
# `started` alone rebooted tappaas1 mid-migration and killed five live guests).
rn_ha_left_on_node() {
    local node="$1"
    havm_ha_services_on_node "$(rn_node_fqdn "$node")" "$node" 2>/dev/null \
        | awk '$1 != "" && $3 !~ /^(stopped|disabled|ignored|error)$/'
}

# Where the CRM would put <sid> when <node> drains (#827): the highest-priority
# other node of its node-affinity rule that is online, else every other online
# node. Pure. Args: <node> <sid> <rules-json> <online-nodes, space-separated>
rn_drain_targets() {
    local node="$1" sid="$2" rules="$3" online="$4"
    jq -r --arg n "${node}" --arg s "${sid}" --arg on " ${online} " '
        [ .[] | select((.type // "node-affinity") == "node-affinity")
              | select(((.resources // "") | split(",")) | index($s)) ][0] as $r
        | ($on | split(" ") | map(select(. != "" and . != $n))) as $others
        | if $r == null then $others[]
          else
            [ ($r.nodes // "") | split(",")[] | select(. != "")
              | split(":") | {node: .[0], prio: ((.[1] // "0") | tonumber)}
              | . as $e | select($e.node != $n and ($others | index($e.node) != null)) ] as $c
            | if ($c | length) == 0 then empty
              else ($c | max_by(.prio).prio) as $top | $c[] | select(.prio == $top) | .node end
          end' <<< "${rules}"
}

# A guest's haCpu, from its module config (named after the VM); common when
# undeclared. A `host` guest is moved by stop and start, never live (#827).
rn_ha_cpu_mode() {
    jq -r '[.. | objects | select(has("haCpu")) | .haCpu][0] // "common"' \
        "${CONFIG_DIR:-/home/tappaas/config}/$1.json" 2>/dev/null || echo common
}

# Running haCpu-host HA guests on <node> and where each goes: "<sid> <name> <target>".
rn_host_guests() {
    local node="$1" res rules online sid vmid name status t
    res="$(rn_node_ssh "$node" "pvesh get /cluster/resources --output-format json" 2>/dev/null)" || return 1
    jq -e 'type == "array"' <<< "${res}" >/dev/null 2>&1 || return 1
    rules="$(rn_node_ssh "$node" "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null)" || rules="[]"
    jq -e 'type == "array"' <<< "${rules}" >/dev/null 2>&1 || rules="[]"
    online="$(jq -r '[.[] | select(.type == "node" and .status == "online") | .node] | join(" ")' <<< "${res}")"
    for sid in $(rn_ha_vms_on_node "$node"); do
        vmid="${sid#vm:}"
        read -r name status < <(jq -r --argjson v "${vmid}" \
            '.[] | select(.type == "qemu" and .vmid == $v) | "\(.name) \(.status)"' <<< "${res}") || true
        [[ "${status:-}" == "running" && "$(rn_ha_cpu_mode "${name}")" == "host" ]] || continue
        t="$(rn_drain_targets "$node" "$sid" "$rules" "$online" | head -1)"
        [[ -n "${t}" ]] && echo "${sid} ${name} ${t}"
    done
}

# Move <sid> to <target> by stop, move, start (HA relocate) and wait until it
# runs there. Args: <any-node> <sid> <target>
rn_relocate() {
    local via="$1" sid="$2" target="$3" waited=0 row
    rn_node_ssh "$via" "ha-manager crm-command relocate ${sid} ${target}" >/dev/null 2>&1 || return 1
    while :; do
        row="$(rn_node_ssh "$target" "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r --argjson v "${sid#vm:}" '.[] | select(.vmid == $v) | "\(.node) \(.status)"' 2>/dev/null)" || row=""
        [[ "${row}" == "${target} running" ]] && return 0
        [[ ${waited} -ge ${RN_DRAIN_MAX:-600} ]] && return 1
        sleep 5; (( waited+=5 ))
    done
}

# Running HA guests on <node> that a drain would move LIVE to a node whose CPU
# lacks features they may be using (#827) — the CRM's maintenance drain does not
# ask, so this asks for it: `proxmox-controller live-ok`, per guest, per target.
# Prints "<sid> <name> → <target>" for each; "cannot tell" counts as unsafe.
# rc 1 when the cluster's guests cannot be read at all.
rn_live_unsafe_guests() {
    local node="$1" res rules online sid vmid name status t
    res="$(rn_node_ssh "$node" "pvesh get /cluster/resources --output-format json" 2>/dev/null)" || res=""
    jq -e 'type == "array"' <<< "${res}" >/dev/null 2>&1 || return 1
    rules="$(rn_node_ssh "$node" "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null)" || rules=""
    jq -e 'type == "array"' <<< "${rules}" >/dev/null 2>&1 || rules="[]"
    online="$(jq -r '[.[] | select(.type == "node" and .status == "online") | .node] | join(" ")' <<< "${res}")"
    for sid in $(rn_ha_vms_on_node "$node"); do
        vmid="${sid#vm:}"
        read -r name status < <(jq -r --argjson v "${vmid}" \
            '.[] | select(.type == "qemu" and .vmid == $v) | "\(.name) \(.status)"' <<< "${res}") || true
        [[ "${status:-}" == "running" ]] || continue
        # haCpu host: relocated (stop/start) before the drain, never moved live.
        [[ "$(rn_ha_cpu_mode "${name}")" == "host" ]] && continue
        for t in $(rn_drain_targets "$node" "$sid" "$rules" "$online"); do
            "${RN_LIVEOK_BIN:-proxmox-controller}" live-ok "$name" "$t" >/dev/null 2>&1 && continue
            echo "${sid} ${name} → ${t}"
        done
    done
}

# Perform a controlled reboot of a single node. Returns 0 on success, 3 when
# the node was left alone because draining it is not live-safe (#827: nothing
# moved, nothing to undo), other non-zero on any failure (caller decides whether
# to abort the run). Assumes the caller has already confirmed/authorised the
# action.
#
# Arguments: <node>
# Empty <node> of its HA guests, as a reboot does (#40 shares it with the lan
# uplink change): quorum check, the #827 live-safety guard, haCpu host guests
# relocated by stop/start, HA maintenance mode, wait for the drain. Leaves the
# node in maintenance on success; rn_undrain_node brings it back. Sets RN_MOVED
# (the relocated host guests, for rn_undrain_node). RN_DRAIN_FOR names what the
# drain is for in its refusal ("rebooted").
# Returns 0 drained, 1 failed (maintenance restored), 3 unsafe (nothing moved).
rn_drain_node() {
    local node="$1" active local_wait=0
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

    # #827: maintenance moves every HA guest LIVE, and the CRM does not check
    # that the target can run what the guest may be using. Refuse the drain —
    # before anything moves — when a guest would land on a CPU missing features.
    local unsafe=""
    if ! unsafe="$(rn_live_unsafe_guests "$node")"; then
        unsafe="(could not read the cluster's guests — not draining blind)"
    fi
    # In the update window (RN_COLD_MOVE_OK=1: automaticReboot, the scheduled
    # run) such a guest is moved the way it can be: stop, move, start — which
    # also brings up a CPU change its update saved for the next restart. Not the
    # controller's own VM: it cannot stop itself mid-run.
    if [[ -n "${unsafe}" && "${RN_COLD_MOVE_OK:-0}" == 1 && "${unsafe}" != "("* ]]; then
        local _seen=" " _cs _cn _ct _arrow _cicd=""
        while read -r _cs _cn _arrow _ct; do
            [[ -n "${_cs}" && "${_seen}" != *" ${_cs} "* ]] || continue
            _seen+="${_cs} "
            if [[ -n "${RN_CICD_VMID:-}" && "${_cs}" == "vm:${RN_CICD_VMID}" ]]; then
                _cicd="${_cn} ${_ct}"; continue
            fi
            info "  Moving ${_cn} to ${_ct} by stop, move, start (it cannot move live)..."
            rn_relocate "$node" "$_cs" "$_ct" \
                || { error "Moving ${_cn} to ${_ct} failed — ${node} not drained"; return 1; }
        done <<< "${unsafe}"
        if [[ -n "${_cicd}" ]]; then
            warn "DEFERRED: ${node} not ${RN_DRAIN_FOR:-rebooted} — the controller's own VM ${_cicd% *} cannot move live to ${_cicd#* },"
            warn "  and it cannot stop itself. Move it once from a node's shell (it is down for a minute):"
            warn "    ha-manager crm-command relocate vm:${RN_CICD_VMID} ${_cicd#* }"
            warn "  The next run then reboots ${node}."
            return 3
        fi
        unsafe="$(rn_live_unsafe_guests "$node")" || unsafe="(could not read the cluster's guests — not draining blind)"
    fi
    if [[ -n "${unsafe}" ]]; then
        warn "DEFERRED: ${node} not ${RN_DRAIN_FOR:-rebooted} — draining it would move HA guests LIVE to a CPU lacking features they may use:"
        while IFS= read -r _l; do warn "    ${_l}"; done <<< "${unsafe}"
        warn "  Nothing was moved. Their cluster:ha update sets a CPU model both nodes run (haCpu: common,"
        warn "  the default) — in effect once each guest restarts — or haCpu: host moves them by stop/start."
        warn "  Until then: move them offline (module-manager migrate <module> --force), then try again"
        return 3
    fi

    # haCpu host guests (#827): off this node by stop and start, before the
    # drain could move them live; back the same way once the node is back.
    RN_MOVED=""; local _sid _name _to
    if ! RN_MOVED="$(rn_host_guests "$node")"; then
        error "Could not read ${node}'s HA guests — not draining it"
        return 1
    fi
    while read -r _sid _name _to; do
        [[ -n "${_sid}" ]] || continue
        info "  Relocating ${_name} (haCpu host) to ${_to} — stop, move, start..."
        rn_relocate "$node" "$_sid" "$_to" \
            || { error "Relocating ${_name} to ${_to} failed — ${node} not drained"; return 1; }
    done <<< "${RN_MOVED}"

    # HA maintenance mode → migrate managed VMs off this node.
    info "  Enabling HA maintenance mode..."
    rn_node_ssh "$node" "ha-manager crm-command node-maintenance enable ${node}" \
        || { error "Failed to enable HA maintenance mode on ${node}"; return 1; }

    # Drain: wait until no live HA service is left on this node, migrating ones
    # included (rn_ha_left_on_node). A 16 GiB guest took 86s alongside four
    # others, so the budget is RN_DRAIN_MAX (600s), not the old 120s.
    while [[ -n "$(rn_ha_left_on_node "$node" || true)" ]]; do
        sleep 5; (( local_wait+=5 ))
        if [[ $local_wait -ge ${RN_DRAIN_MAX:-600} ]]; then
            error "HA migration timeout on ${node} after ${local_wait}s (raise RN_DRAIN_MAX): $(rn_ha_left_on_node "$node" | awk '{printf "%s=%s ", $1, $3}')"
            # #507: the reboot has NOT happened yet, so the VMs are still on this
            # node — restore the pre-attempt HA state rather than stranding it in
            # maintenance. Leaving it on here is how a CPU-heterogeneous cluster
            # (guests pinned to cputype host, HA unable to live-migrate) accrues a
            # stuck maintenance flag on every reboot attempt. Unlike the
            # post-reboot-unreachable path below, keeping maintenance here buys
            # nothing: the node never went down.
            info "  Disabling HA maintenance mode (drain timed out; nothing else done)..."
            rn_node_ssh "$node" "ha-manager crm-command node-maintenance disable ${node}" \
                || warn "  Could not disable maintenance mode on ${node} — run manually: ha-manager crm-command node-maintenance disable ${node}"
            return 1
        fi
    done
    info "  ${GN}✓${CL} HA VMs migrated off ${node}"
    return 0
}

# Bring a drained <node> back into HA placement: sweep stranded cloud-init
# volumes, clear maintenance (confirmed), wait for the failback to settle, and
# move the haCpu host guests in RN_MOVED back. Non-zero only when maintenance
# could not be cleared.
rn_undrain_node() {
    local node="$1" stuck _sid _name _to
    # Clear any cloud-init volume stranded here, so failback cannot wedge (#146).
    rn_sweep_cloudinit_orphans "$node"

    # Leave maintenance mode → HA migrates VMs back.
    #
    # This used to warn and continue, so a node that never left maintenance was
    # reported as a successful reboot and silently sat out of the cluster — 13
    # hours, in the case that prompted this. A node short of HA placement is a
    # failed reboot, so say so and return non-zero.
    info "  Disabling HA maintenance mode..."
    if ! rn_disable_maintenance "$node"; then
        error "Could not clear maintenance mode on ${node} — it is still excluded from HA placement."
        error "  The cluster is running one node short. Clear it with:"
        error "    ha-manager crm-command node-maintenance disable ${node}"
        return 1
    fi
    info "  ${GN}✓${CL} maintenance mode cleared"

    # Verify the failback actually converged. Without this the reboot reports
    # success while the CRM retries a failing migration forever (#146) — which
    # is exactly how a 27-hour retry loop went unnoticed.
    info "  Waiting for HA to settle..."
    if stuck=$(rn_wait_ha_settled "$node"); then
        info "  ${GN}✓${CL} HA settled — no services in transition"
    else
        warn "  HA did not settle after ${RN_HA_SETTLE_MAX:-180}s (raise RN_HA_SETTLE_MAX); still in transition:"
        while IFS= read -r _svc; do
            [[ -n "$_svc" ]] && warn "      ${_svc}"
        done <<< "${stuck}"
        warn "  Check for a stale cloud-init volume blocking migration:"
        warn "    ${RN_LIB_DIR}/../cloudinit-orphans.sh"
    fi

    # The haCpu host guests come back as they left: stop, move, start. Their
    # failback is off, so the CRM leaves them where they are.
    while read -r _sid _name _to; do
        [[ -n "${_sid}" ]] || continue
        info "  Relocating ${_name} back to ${node}..."
        rn_relocate "$node" "$_sid" "$node" \
            || warn "  ${_name} did not return to ${node} — it runs on ${_to}; move it with: ha-manager crm-command relocate ${_sid} ${node}"
    done <<< "${RN_MOVED}"

    return 0
}

reboot_one_node() {
    local node="$1"
    local latest new_running old_boot_id

    info "${BOLD}Rebooting ${node}${CL}"

    latest=$(rn_latest_kernel "$node")

    local _drc=0
    rn_drain_node "$node" || _drc=$?
    [[ ${_drc} -eq 0 ]] || return "${_drc}"

    # Reboot — the SSH connection drops, which is expected. Remember the boot id
    # first, so the wait can tell a node that has really rebooted from one that
    # is merely slow to go down and still answering SSH.
    old_boot_id=$(rn_node_ssh "$node" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
    info "  Issuing reboot..."
    rn_node_ssh "$node" "reboot" || true
    sleep 15
    if ! rn_wait_for_node "$node" "" "$old_boot_id"; then
        error "Node ${node} did not return within ${RN_WAIT_MAX:-600}s after its reboot (raise RN_WAIT_MAX; left in maintenance mode so HA keeps its VMs elsewhere)"
        return 1
    fi
    info "  ${GN}✓${CL} ${node} is back online"

    # "Answers SSH" is not "is a cluster member" — see rn_node_is_cluster_member.
    # Everything below this point talks to the HA stack, so gate on membership
    # rather than reachability, or the maintenance-disable races the boot.
    if ! rn_wait_cluster_member "$node"; then
        error "${node} rebooted but did not rejoin the cluster within ${RN_CLUSTER_WAIT_MAX:-300}s (raise RN_CLUSTER_WAIT_MAX)"
        error "  It is STILL IN MAINTENANCE MODE and excluded from HA placement. Investigate, then clear with:"
        error "    ha-manager crm-command node-maintenance disable ${node}"
        return 1
    fi
    info "  ${GN}✓${CL} ${node} rejoined the cluster"

    # Verify the new kernel is the one actually running.
    new_running=$(rn_running_kernel "$node")
    if [[ -z "$latest" ]]; then
        info "  ${GN}✓${CL} Running kernel: ${new_running} (no newer kernel pending)"
    elif [[ "$new_running" == "$latest" ]]; then
        info "  ${GN}✓${CL} New kernel active: ${new_running}"
    else
        warn "  ${node} running ${new_running} (expected ${latest}) — check grub default"
    fi

    rn_undrain_node "$node" || return 1

    info "  ${GN}✓${CL} ${node} reboot complete"
    return 0
}
