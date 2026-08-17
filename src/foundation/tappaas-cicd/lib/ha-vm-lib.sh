#!/usr/bin/env bash
# lib/ha-vm-lib.sh — stop/start a cluster VM or container and CONFIRM it happened.
#
# `qm stop` on an HA-managed resource does not stop anything by itself: it hands
# a command to the CRM, which observes and completes it on its own schedule —
# seconds to tens of seconds later. A caller that issues the stop, sleeps a fixed
# interval and moves on is racing the cluster.
#
# That race is #434. snapshot-vm.sh --restore stopped an HA VM, slept 3s, rolled
# back, and issued `qm start` while the stop was still queued. The CRM first saw
# the stop 5s in and finished it at 15s, settling the service on the 'stopped'
# it had been asked for — after the start had already gone by. Nothing started it
# again, and the run reported the restore as successful. The VM was the site's
# gateway; it stayed down 7h41m until an operator started it by hand.
#
# The rules these helpers encode:
#   - drive an HA resource through `ha-manager set --state`, never qm/pct, so the
#     requested state the CRM converges on is the state we actually want;
#   - confirm every transition by polling real state, bounded by a timeout;
#   - return non-zero on timeout or on a failed command, so a caller fails loudly
#     instead of announcing a success it never verified.
#
# Callers define info()/warn()/error(); we only add fallbacks if they are missing.
# Tested with `declare -F`, not `command -v`: `info` is also a real binary
# (texinfo) on a NixOS host, so `command -v info` succeeds even when no logging
# function exists and every info call would run the texinfo reader instead.
declare -F info  >/dev/null || info()  { echo "$*"; }
declare -F warn  >/dev/null || warn()  { echo "WARN: $*" >&2; }
declare -F error >/dev/null || error() { echo "ERROR: $*" >&2; }

# Seconds between polls. Kept small enough to not add latency of its own, large
# enough that a 180s wait is ~60 ssh round trips, not 180. Tests override it.
: "${HAVM_POLL_INTERVAL:=3}"

# Set by havm_stop: 1 when it asked the CRM to stop the resource. Read by callers
# whose abort path has to hand the resource back to HA. It is set BEFORE the wait,
# so it is true even when havm_stop subsequently fails — which is precisely the
# case where the hand-back matters.
HAVM_LAST_STOP_WAS_HA=0

# Run one command on a cluster node. TAPPAAS_HAVM_EXEC replaces the ssh with a
# stub taking the same (node_fqdn, command) arguments — the seam test-ha-vm-lib.sh
# uses to exercise CRM timing offline.
havm_exec() {
    local node_fqdn="$1" cmd="$2"
    if [[ -n "${TAPPAAS_HAVM_EXEC:-}" ]]; then
        "${TAPPAAS_HAVM_EXEC}" "${node_fqdn}" "${cmd}"
    else
        # -n: never read local stdin. These are all command-only calls, and a
        # caller with an interactive confirmation (reboot-node.sh) would
        # otherwise have its prompt eaten by ssh.
        ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
            -o StrictHostKeyChecking=accept-new \
            "root@${node_fqdn}" "${cmd}"
    fi
}

# ── `ha-manager status` parsing ──────────────────────────────────────
# One parser, because there were four. snapshot-vm, migrate-vm, reboot-node-lib
# and check-ha-health each grew their own, and they did not agree: migrate-vm's
# `grep "vm:${vmid}" | awk '{print $3}'` read the NODE as the state, and its
# unanchored grep matched vm:1300 when asked for vm:130.
#
# `ha-manager status` prints:
#   quorum OK
#   master tappaas1 (active, Mon Aug 17 12:00:00 2026, ...)
#   lrm tappaas2 (idle, ...)
#   service vm:130 (tappaas2, started)

# HA service states that are stable resting places; anything else means the CRM
# is still working on it.
HAVM_STEADY_STATES="started stopped disabled ignored freeze"

# Emit one `<sid> <node> <state>` line per HA service.
# rc 1 when the status query itself failed, so callers can tell "no HA services"
# apart from "could not ask" — conflating those is how an unreachable cluster
# starts looking like a cluster with nothing to do.
#
# TAPPAAS_HA_STATUS_FILE supplies a canned `ha-manager status` instead of
# querying a node — check-ha-health.sh's long-standing offline test hook, kept
# here so its suite keeps working now that it reads through this parser.
# Args: <node_fqdn>
havm_ha_services() {
    local node_fqdn="$1" status
    if [[ -n "${TAPPAAS_HA_STATUS_FILE:-}" ]]; then
        status=$(cat "${TAPPAAS_HA_STATUS_FILE}") || return 1
    else
        status=$(havm_exec "${node_fqdn}" "ha-manager status" 2>/dev/null) || return 1
    fi
    # A working node always prints at least `quorum OK`, so empty output is a
    # failed query wearing a zero exit status — not a cluster with no services.
    [[ -n "${status}" ]] || return 1
    printf '%s\n' "${status}" \
        | awk '$1 == "service" { gsub(/[(),]/, ""); print $2, $3, $4 }'
}

# HA services on one node, optionally only those in <state>.
# Args: <node_fqdn> <node> [state]
havm_ha_services_on_node() {
    local node_fqdn="$1" want_node="$2" want_state="${3:-}" svc
    svc=$(havm_ha_services "${node_fqdn}") || return 1
    printf '%s\n' "${svc}" \
        | awk -v n="${want_node}" -v s="${want_state}" \
            '$1 != "" && $2 == n && (s == "" || $3 == s)'
}

# Services the CRM is still moving, as `<sid>=<state>`; empty output means the
# cluster has settled.
# Args: <node_fqdn>
havm_ha_unsettled() {
    local node_fqdn="$1" svc
    svc=$(havm_ha_services "${node_fqdn}") || return 1
    printf '%s\n' "${svc}" \
        | awk -v steady=" ${HAVM_STEADY_STATES} " \
            '$1 != "" && index(steady, " " $3 " ") == 0 { print $1 "=" $3 }'
}

# HA resource id for a VMID. HA addresses QEMU VMs as vm:<id> and LXC containers
# as ct:<id> — the wrong prefix does not error, it silently matches no service,
# which reads back as "not HA-managed".
# Args: <vm_type: qemu|lxc> <vmid>
havm_resource_id() {
    local vm_type="$1" vmid="$2"
    case "${vm_type}" in
        lxc|ct) printf 'ct:%s' "${vmid}" ;;
        *)      printf 'vm:%s' "${vmid}" ;;
    esac
}

# Is this resource HA-managed, and in what state?
#   rc 0 — HA-managed; the state is printed ('started', 'request_stop', ...)
#   rc 1 — not HA-managed
#   rc 2 — could not tell (the status query itself failed)
#
# The three are kept apart on purpose. Folding rc 2 into rc 1 would make an
# unreachable or busy cluster look like a plain non-HA VM, and send the caller
# down the raw qm/pct path — reinstating the exact race this lib exists to close.
# Args: <node_fqdn> <resource_id>
havm_ha_probe() {
    local node_fqdn="$1" rid="$2" svc state
    svc=$(havm_ha_services "${node_fqdn}") || return 2
    state=$(printf '%s\n' "${svc}" | awk -v rid="${rid}" '$1 == rid { print $3; exit }')
    [[ -n "${state}" ]] || return 1
    printf '%s' "${state}"
}

# Current HA state, or empty when the resource is not HA-managed or unreadable.
# For messages; decisions should use havm_ha_probe so rc 2 stays visible.
# Args: <node_fqdn> <resource_id>
havm_ha_state() {
    havm_ha_probe "$1" "$2" || true
}

# True only when the resource is definitely HA-managed (a failed probe is not).
# Args: <node_fqdn> <resource_id>
havm_is_ha_managed() {
    havm_ha_probe "$1" "$2" >/dev/null
}

# Status of a VMID ('running' / 'stopped'), read through the cluster API rather
# than `qm status` so it answers from any node — an HA resource may not be on the
# node we are talking to, and after a failover it usually is not.
# Args: <node_fqdn> <vmid>
havm_status() {
    local node_fqdn="$1" vmid="$2"
    havm_exec "${node_fqdn}" "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and (.type == "qemu" or .type == "lxc")) | .status // empty' 2>/dev/null \
        || true
}

havm_poll_interval() {
    local iv="${HAVM_POLL_INTERVAL:-3}"
    [[ "${iv}" =~ ^[0-9]+$ && "${iv}" -ge 1 ]] || iv=1
    printf '%s' "${iv}"
}

# Poll until the VM reaches <want>, or <timeout_s> elapses. 0 on match, 1 on timeout.
# Args: <node_fqdn> <vmid> <want> <timeout_s>
havm_wait_status() {
    local node_fqdn="$1" vmid="$2" want="$3" timeout="$4"
    local waited=0 iv status
    iv=$(havm_poll_interval)
    while true; do
        status=$(havm_status "${node_fqdn}" "${vmid}")
        [[ "${status}" == "${want}" ]] && return 0
        [[ "${waited}" -ge "${timeout}" ]] && return 1
        sleep "${iv}"
        waited=$((waited + iv))
    done
}

# Poll until the HA resource reaches <want>, or <timeout_s> elapses. This is the
# wait the fixed `sleep 3` replaced: the CRM's own state machine, not the guest's.
# Args: <node_fqdn> <resource_id> <want> <timeout_s>
havm_wait_ha_state() {
    local node_fqdn="$1" rid="$2" want="$3" timeout="$4"
    local waited=0 iv state
    iv=$(havm_poll_interval)
    while true; do
        state=$(havm_ha_state "${node_fqdn}" "${rid}")
        [[ "${state}" == "${want}" ]] && return 0
        [[ "${waited}" -ge "${timeout}" ]] && return 1
        sleep "${iv}"
        waited=$((waited + iv))
    done
}

# Stop a VM/CT and confirm it stopped. HA resources go through the CRM; everything
# else through qm/pct, whose exit status is checked — a stop that failed must not
# be followed by a rollback over a still-running disk.
# Args: <node_fqdn> <vmid> <vm_type> [timeout_s]
# Returns 0 only once the resource is actually stopped.
# Sets HAVM_LAST_STOP_WAS_HA for the caller's abort path.
havm_stop() {
    local node_fqdn="$1" vmid="$2" vm_type="$3" timeout="${4:-180}"
    local rid cmd status probe_rc
    rid=$(havm_resource_id "${vm_type}" "${vmid}")
    cmd="qm"; [[ "${vm_type}" == "lxc" ]] && cmd="pct"
    HAVM_LAST_STOP_WAS_HA=0

    status=$(havm_status "${node_fqdn}" "${vmid}")
    if [[ "${status}" == "stopped" ]]; then
        info "  ${rid} is already stopped"
        return 0
    fi

    probe_rc=0; havm_ha_probe "${node_fqdn}" "${rid}" >/dev/null || probe_rc=$?
    if [[ "${probe_rc}" -eq 2 ]]; then
        error "Could not determine whether ${rid} is HA-managed (ha-manager status failed on ${node_fqdn}) — refusing to guess"
        return 1
    fi

    if [[ "${probe_rc}" -eq 0 ]]; then
        # Set BEFORE the request: if the wait below times out, the CRM has still
        # been told to stop, and the caller's abort path must hand it back.
        # shellcheck disable=SC2034  # read by callers of this lib
        HAVM_LAST_STOP_WAS_HA=1
        info "  ${rid} is HA-managed — requesting stop via the CRM..."
        if ! havm_exec "${node_fqdn}" "ha-manager set ${rid} --state stopped"; then
            error "ha-manager set ${rid} --state stopped failed"
            return 1
        fi
        if ! havm_wait_ha_state "${node_fqdn}" "${rid}" stopped "${timeout}"; then
            local seen; seen=$(havm_ha_state "${node_fqdn}" "${rid}")
            error "${rid} did not reach HA state 'stopped' within ${timeout}s (state: ${seen:-unknown})"
            return 1
        fi
    else
        info "  Stopping ${rid}..."
        if ! havm_exec "${node_fqdn}" "${cmd} stop ${vmid}"; then
            error "${cmd} stop ${vmid} failed"
            return 1
        fi
    fi

    if ! havm_wait_status "${node_fqdn}" "${vmid}" stopped "${timeout}"; then
        error "VM ${vmid} did not stop within ${timeout}s (status: $(havm_status "${node_fqdn}" "${vmid}"))"
        return 1
    fi
    info "  ${rid} stopped"
    return 0
}

# Start a VM/CT and confirm it is running.
#
# For an HA resource this also puts the requested state back to 'started'. That
# is not decoration: after havm_stop the CRM's requested state IS 'stopped', so a
# bare `qm start` is something the CRM will undo. Asking HA for 'started' is what
# makes the start stick.
# Args: <node_fqdn> <vmid> <vm_type> [timeout_s]
havm_start() {
    local node_fqdn="$1" vmid="$2" vm_type="$3" timeout="${4:-180}"
    local rid cmd probe_rc
    rid=$(havm_resource_id "${vm_type}" "${vmid}")
    cmd="qm"; [[ "${vm_type}" == "lxc" ]] && cmd="pct"

    probe_rc=0; havm_ha_probe "${node_fqdn}" "${rid}" >/dev/null || probe_rc=$?
    if [[ "${probe_rc}" -eq 2 ]]; then
        error "Could not determine whether ${rid} is HA-managed (ha-manager status failed on ${node_fqdn}) — refusing to guess"
        return 1
    fi

    if [[ "${probe_rc}" -eq 0 ]]; then
        info "  ${rid} is HA-managed — requesting start via the CRM..."
        if ! havm_exec "${node_fqdn}" "ha-manager set ${rid} --state started"; then
            error "ha-manager set ${rid} --state started failed"
            return 1
        fi
        if ! havm_wait_ha_state "${node_fqdn}" "${rid}" started "${timeout}"; then
            local seen; seen=$(havm_ha_state "${node_fqdn}" "${rid}")
            error "${rid} did not reach HA state 'started' within ${timeout}s (state: ${seen:-unknown})"
            return 1
        fi
    else
        info "  Starting ${rid}..."
        if ! havm_exec "${node_fqdn}" "${cmd} start ${vmid}"; then
            error "${cmd} start ${vmid} failed"
            return 1
        fi
    fi

    if ! havm_wait_status "${node_fqdn}" "${vmid}" running "${timeout}"; then
        error "VM ${vmid} is not running within ${timeout}s of the start (status: $(havm_status "${node_fqdn}" "${vmid}"))"
        return 1
    fi
    info "  ${rid} running"
    return 0
}

# Best-effort hand-back of an HA resource to 'started'.
#
# For the abort paths of a stop → mutate → start sequence. If the caller gives up
# after the stop, the CRM's requested state is still 'stopped' and it will hold
# the resource down indefinitely — the #434 outage, reached by a different route.
# Never fails the caller; the point is to leave the cluster wanting the VM up.
# Args: <node_fqdn> <resource_id>
havm_release_ha_stop() {
    local node_fqdn="$1" rid="$2"
    havm_exec "${node_fqdn}" "ha-manager set ${rid} --state started" >/dev/null 2>&1 \
        || warn "Could not hand ${rid} back to HA — run: ha-manager set ${rid} --state started"
}
