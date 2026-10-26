#!/usr/bin/env bash
#
# test-reboot-node-lib.sh — unit tests for reboot_one_node's maintenance-mode paths.
#
# Drives reboot_one_node to the HA-migration timeout with stubbed cluster calls
# (no ssh, no Proxmox, no waiting) and asserts it DISABLES HA maintenance mode
# before returning — restoring the pre-attempt state instead of stranding the
# node in maintenance — and that it does NOT proceed to reboot on that path.
#
# Usage: ./test-reboot-node-lib.sh   Exit: 0 all passed, 1 otherwise.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colour vars + logging stubs so the lib can be sourced standalone under set -u.
BOLD=""; GN=""; CL=""; YW=""; RD=""; BL=""
: "${BOLD}${GN}${CL}${YW}${RD}${BL}"  # referenced by the sourced lib, not here
info()  { :; }
debug() { :; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERR: $*"  >&2; }
die()   { echo "DIE: $*"  >&2; exit 1; }

# shellcheck source=reboot-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/reboot-node-lib.sh"

PASS=0
FAIL=0
pass() { echo "  ok: $*";   PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SSH_LOG="${WORK}/ssh.log"; : > "${SSH_LOG}"

# ── Stubs: quorum OK, drain never completes, record every ssh command ──
sleep() { :; }                                   # no real waiting
rn_ha_active_count()       { echo 2; }           # quorum OK (>=2)
rn_latest_kernel()         { echo "6.1.0-test"; }
rn_node_fqdn()             { echo "$1"; }
havm_ha_services_on_node() { echo "vm:100"; }    # a VM never drains off → timeout
rn_node_ssh() { shift; printf '%s\n' "$*" >> "${SSH_LOG}"; return 0; }
rn_live_unsafe_guests()    { :; }                # #827 guard: every drain live-safe here
rn_host_guests()           { :; }                # …and no haCpu-host guest to relocate

# ── Drive it ─────────────────────────────────────────────────────────
reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?

if [[ "${rc}" -ne 0 ]]; then
    pass "reboot_one_node returns non-zero on drain timeout"
else
    fail "reboot_one_node should return non-zero on drain timeout (got ${rc})"
fi

if grep -q 'node-maintenance disable testnode' "${SSH_LOG}"; then
    pass "drain timeout disables HA maintenance mode (#507)"
else
    fail "drain timeout did NOT disable maintenance mode — node stranded (#507); ssh log: $(tr '\n' ';' < "${SSH_LOG}")"
fi

if grep -qx 'reboot' "${SSH_LOG}"; then
    fail "drain timeout must NOT reboot the node"
else
    pass "drain timeout does not reboot the node"
fi


# ── Drain must wait out `migrate`, not just `started` (2026-10-08) ───
(
    LOG="${WORK}/m.log"; : > "${LOG}"; N="${WORK}/m.n"; echo 0 > "${N}"
    sleep() { :; }
    rn_ha_active_count() { echo 2; }
    rn_latest_kernel()   { echo ""; }
    rn_node_fqdn()       { echo "$1"; }
    rn_wait_for_node()   { return 1; }           # stop right after the reboot
    # Three polls in `migrate`, then the service is on the other node.
    havm_ha_services_on_node() {
        local n; n=$(( $(cat "${N}") + 1 )); echo "${n}" > "${N}"
        # Honour the optional state filter the way the real helper does.
        if (( n <= 3 )) && [[ -z "${3:-}" || "${3}" == migrate ]]; then echo "vm:130 testnode migrate"; fi
    }
    rn_node_ssh() {
        shift; printf '%s\n' "$*" >> "${LOG}"
        [[ "$*" == reboot ]] && echo "polls=$(cat "${N}")" >> "${LOG}"
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1
    grep -qx 'polls=4' "${LOG}"
) && pass "drain waits while a service is in migrate, reboots after it left" \
  || fail "drain rebooted with a service still migrating"

(
    sleep() { :; }
    rn_node_fqdn() { echo "$1"; }
    havm_ha_services_on_node() { printf '%s\n' "vm:1 testnode stopped" "vm:2 testnode disabled" "vm:3 testnode ignored"; }
    [[ -z "$(rn_ha_left_on_node testnode)" ]]
) && pass "stopped/disabled/ignored services do not block the drain" \
  || fail "a service with nothing running blocked the drain"

# ── Post-reboot maintenance-disable scenarios ────────────────────────
#
# A node that reboots and never leaves maintenance mode sits out of HA
# placement indefinitely. It used to be reported as a successful reboot, which
# hid exactly that for 13 hours (2026-08-25). Each scenario runs in a subshell
# so it can carry its own stubs.
#
# `state` holds the simulated LRM line; the rn_node_ssh stub answers
# `ha-manager status` from it, so membership and the maintenance flag are
# observable the same way the real code observes them.

# Shared stubs for a node that drains and reboots cleanly.
scenario_common() {
    rn_ha_active_count()          { echo 2; }
    rn_latest_kernel()            { echo "6.1.0-test"; }
    rn_running_kernel()           { echo "6.1.0-test"; }
    rn_node_fqdn()                { echo "$1"; }
    havm_ha_services_on_node()    { echo ""; }      # drains immediately
    rn_wait_for_node()            { return 0; }     # comes back on the first probe
    rn_sweep_cloudinit_orphans()  { :; }
    rn_wait_ha_settled()          { return 0; }
    RN_CLUSTER_WAIT_MAX=10
    RN_MAINT_DISABLE_TRIES=2
}

# A: node rejoins and the disable takes effect → success, flag cleared.
(
    scenario_common
    STATE="${WORK}/a.state"; echo "maintenance mode" > "${STATE}"
    LOG="${WORK}/a.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"ha-manager status"*) echo "lrm ${node} ($(cat "${STATE}"), watchdog)" ;;
            *"node-maintenance disable"*) echo "active" > "${STATE}" ;;
        esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -eq 0 ]] && grep -q "active" "${STATE}"
) && pass "clean reboot clears maintenance mode and returns 0" \
  || fail "clean reboot should clear maintenance and return 0"

# B: node reboots but never rejoins the cluster → non-zero, and the HA stack is
# never touched (the disable must not be attempted against a non-member).
(
    scenario_common
    LOG="${WORK}/b.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        # `ha-manager status` answers, but never lists this node's LRM.
        case "$*" in *"ha-manager status"*) echo "lrm othernode (active, watchdog)" ;; esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -ne 0 ]] && ! grep -q 'node-maintenance disable' "${LOG}"
) && pass "node that never rejoins the cluster fails the reboot, no HA call made" \
  || fail "a node that never rejoins must fail the reboot without calling ha-manager"

# C: the regression under test. The node is a member, but the disable is
# rejected every time (as `no such cluster node` did) and the flag never
# clears. This MUST fail the reboot rather than warn and report success.
(
    scenario_common
    STATE="${WORK}/c.state"; echo "maintenance mode" > "${STATE}"
    LOG="${WORK}/c.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"ha-manager status"*) echo "lrm ${node} ($(cat "${STATE}"), watchdog)" ;;
            *"node-maintenance disable"*) echo "no such cluster node '${node}'" ;;  # never clears
        esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -ne 0 ]] && [[ "$(grep -c 'node-maintenance disable' "${LOG}")" -ge 2 ]]
) && pass "a disable that never takes effect fails the reboot (and is retried)" \
  || fail "a stuck maintenance flag must fail the reboot, not warn"

# ── #827: a drain that is not live-safe is refused before anything moves ──
RULES='[{"rule":"ha-a","type":"node-affinity","resources":"vm:110","nodes":"n1:2,n3:1"},
        {"rule":"ha-b","type":"node-affinity","resources":"vm:120,vm:121","nodes":"n1:2,n2:1,n3:1"}]'
check_targets() {  # <want> <node> <sid> <online>
    local got; got="$(rn_drain_targets "$2" "$3" "${RULES}" "$4" | sort | tr '\n' ' ')"
    [[ "${got}" == "$1" ]] && pass "drain target of $3 from $2 (online: $4): ${got:-none}" \
                           || fail "drain target of $3 from $2: got '${got}', want '$1'"
}
check_targets "n3 "     n1 vm:110 "n1 n2 n3"    # the rule's other node, not any node
check_targets "n1 "     n3 vm:110 "n1 n2 n3"    # back to the preferred one
check_targets "n2 n3 "  n1 vm:121 "n1 n2 n3"    # a tie: either may be chosen
check_targets "n3 "     n1 vm:121 "n1 n3"       # an offline node is not a target
check_targets "n2 n3 "  n1 vm:999 "n1 n2 n3"    # no rule: any other online node
check_targets ""        n1 vm:110 "n1 n2"       # its only partner is down

(
    . "${SCRIPT_DIR}/reboot-node-lib.sh"
    LOG="${WORK}/g.log"; : > "${LOG}"
    sleep() { :; }
    rn_ha_active_count() { echo 2; }
    rn_latest_kernel()   { echo ""; }
    rn_node_fqdn()       { echo "$1"; }
    havm_ha_services_on_node() { printf 'vm:110 n1 started\nvm:111 n1 started\n'; }
    rn_node_ssh() {
        shift; printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"/cluster/resources"*) echo '[{"type":"node","node":"n1","status":"online"},{"type":"node","node":"n3","status":"online"},
                                          {"type":"qemu","vmid":110,"name":"network","status":"running"},
                                          {"type":"qemu","vmid":111,"name":"spare","status":"stopped"}]' ;;
            *"/cluster/ha/rules"*)  echo "${RULES}" ;;
        esac
        return 0
    }
    printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n[ "$3" = n3 ] && exit 2; exit 0\n' "${WORK}/liveok.log" > "${WORK}/liveok"
    chmod +x "${WORK}/liveok"; export RN_LIVEOK_BIN="${WORK}/liveok"

    out="$(rn_live_unsafe_guests n1)"
    [[ "${out}" == "vm:110 network → n3" ]] && pass "a running guest bound for a lesser CPU is named: ${out}" \
                                             || fail "unsafe guests: got '${out}'"
    grep -q "spare" "${WORK}/liveok.log" && fail "a stopped guest was checked" || pass "a stopped guest is not checked (it moves cold)"

    rc=0; reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    [[ ${rc} -eq 3 ]] && pass "reboot_one_node returns 3 (left alone) for an unsafe drain" || fail "unsafe drain rc ${rc}, want 3"
    grep -q 'node-maintenance enable' "${LOG}" && fail "maintenance was enabled despite an unsafe drain" \
                                              || pass "…and never enables maintenance: nothing moves"

    : > "${LOG}"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/liveok"
    rn_wait_for_node() { return 1; }
    rc=0; reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    grep -q 'node-maintenance enable n1' "${LOG}" && pass "a live-safe drain proceeds to maintenance" || fail "a live-safe drain did not enable maintenance"

    : > "${LOG}"
    rn_node_ssh() { shift; printf '%s\n' "$*" >> "${LOG}"; echo "garbage"; }
    rc=0; reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    [[ ${rc} -eq 3 ]] && ! grep -q 'node-maintenance enable' "${LOG}" \
        && pass "unreadable cluster state: not drained blind (rc 3)" || fail "unreadable state: rc ${rc}"

    # haCpu host: relocated by stop/start before maintenance, back afterwards,
    # and never counted as a live-unsafe move.
    export CONFIG_DIR="${WORK}/cfg"; mkdir -p "${CONFIG_DIR}"
    echo '{"vmname":"network","haCpu":"host"}' > "${CONFIG_DIR}/network.json"
    echo n1 > "${WORK}/where"
    : > "${LOG}"
    rn_node_ssh() {
        shift; printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"crm-command relocate vm:110 "*) echo "${*##* }" > "${WORK}/where" ;;
            *"--type vm"*) echo "[{\"type\":\"qemu\",\"vmid\":110,\"node\":\"$(cat "${WORK}/where")\",\"status\":\"running\"}]" ;;
            *"/cluster/resources"*) echo '[{"type":"node","node":"n1","status":"online"},{"type":"node","node":"n3","status":"online"},
                                          {"type":"qemu","vmid":110,"name":"network","status":"running"}]' ;;
            *"/cluster/ha/rules"*)  echo "${RULES}" ;;
            *"ha-manager status"*)  echo "lrm n1 (active, watchdog)" ;;
        esac
        return 0
    }
    printf '#!/usr/bin/env bash\n[ "$3" = n3 ] && exit 2; exit 0\n' > "${WORK}/liveok"
    rn_wait_for_node() { return 0; }
    rn_wait_cluster_member() { return 0; }
    rn_running_kernel() { echo ""; }
    rn_sweep_cloudinit_orphans() { :; }
    rn_disable_maintenance() { return 0; }
    rn_wait_ha_settled() { return 0; }
    rn_ha_left_on_node() { :; }
    out="$(rn_live_unsafe_guests n1)"
    [[ -z "${out}" ]] && pass "a haCpu-host guest is not a live-unsafe move" || fail "host guest listed as unsafe: ${out}"
    rc=0; reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    order="$(grep -E 'relocate|node-maintenance enable|^reboot$' "${LOG}" | tr '\n' ';')"
    [[ ${rc} -eq 0 && "${order}" == "ha-manager crm-command relocate vm:110 n3;ha-manager crm-command node-maintenance enable n1;reboot;ha-manager crm-command relocate vm:110 n1;" ]] \
        && pass "host guest: relocated off, node drained and rebooted, relocated back" \
        || fail "host guest sequence rc=${rc}: ${order}"
    echo "${PASS} ${FAIL}" > "${WORK}/sub.counts"
)
read -r _p _f < "${WORK}/sub.counts" && PASS=${_p} && FAIL=${_f}

# ── the update window (RN_COLD_MOVE_OK=1): a guest that cannot move live is
# moved by stop, move, start, and the node is then drained; never the
# controller's own VM, which cannot stop itself.
(
    . "${SCRIPT_DIR}/reboot-node-lib.sh"
    LOG="${WORK}/c.log"; : > "${LOG}"; MOVED="${WORK}/moved"; : > "${MOVED}"
    sleep() { :; }
    rn_ha_active_count() { echo 2; }
    rn_latest_kernel()   { echo ""; }
    rn_node_fqdn()       { echo "$1"; }
    rn_host_guests()     { :; }
    havm_ha_services_on_node() { :; }
    rn_node_ssh() { shift; printf '%s\n' "$*" >> "${LOG}"; return 0; }
    rn_relocate() { echo "$2 $3" >> "${MOVED}"; }
    # Unsafe until it has been moved.
    rn_live_unsafe_guests() { [[ -s "${MOVED}" ]] || echo "vm:110 network → n3"; }
    rn_wait_for_node() { return 1; }

    rc=0; RN_COLD_MOVE_OK=1 reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    [[ "$(cat "${MOVED}")" == "vm:110 n3" ]] && pass "in the window, an unsafe guest is moved by stop, move, start" \
                                           || fail "cold move: moved '$(cat "${MOVED}")'"
    grep -q 'node-maintenance enable n1' "${LOG}" && pass "…and the node is then drained" || fail "no drain after the cold move"

    : > "${LOG}"; : > "${MOVED}"
    rc=0; RN_COLD_MOVE_OK=1 RN_CICD_VMID=110 reboot_one_node n1 >"${WORK}/c.out" 2>&1 || rc=$?
    [[ ${rc} -eq 3 && ! -s "${MOVED}" ]] && pass "the controller's own VM is never stopped: deferred (3)" \
                                         || fail "cicd guest: rc=${rc} moved='$(cat "${MOVED}")'"
    grep -q 'relocate vm:110 n3' "${WORK}/c.out" && pass "…with the command to move it once by hand" || fail "no hand command: $(cat "${WORK}/c.out")"

    : > "${LOG}"; : > "${MOVED}"
    rc=0; reboot_one_node n1 >/dev/null 2>&1 || rc=$?
    [[ ${rc} -eq 3 && ! -s "${MOVED}" ]] && pass "outside the window nothing is moved" || fail "outside the window: rc=${rc}"
    echo "${PASS} ${FAIL}" > "${WORK}/sub.counts"
)
read -r _p _f < "${WORK}/sub.counts" && PASS=${_p} && FAIL=${_f}

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
