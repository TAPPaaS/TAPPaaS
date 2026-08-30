#!/usr/bin/env bash
#
# test-migrate-vm.sh — unit tests for migrate-vm.sh's stop/start sequencing (#434).
#
# Sources migrate-vm.sh (guarded so main() does not run) and drives
# do_offline_migration / try_live_migration against a stubbed cluster. No ssh, no
# node, no VM: `ssh` is overridden and the ha-vm-lib calls go through
# TAPPAAS_HAVM_EXEC, both landing on one stub that models a CRM which acts N
# polls after being asked — the lag the old hand-rolled waits outran.
#
# What is asserted:
#   - the VM is CONFIRMED stopped before `qm migrate` is issued (an offline
#     migration of a running VM fails);
#   - a stop that never completes aborts the migration instead of proceeding;
#   - the non-HA path escalates a failed graceful shutdown to a hard stop and
#     confirms the result, rather than discarding it;
#   - a VM that does not come up on the target fails the migration, instead of
#     `qm start` returning 0 being taken as proof;
#   - HA detection reports the service STATE, not the node, and matches the
#     service id exactly — the old `grep "vm:${vmid}" | awk '{print $3}'` did
#     neither, printing "(tappaas1," and matching vm:1300 when asked for vm:130.
#
# Usage: ./test-migrate-vm.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="${HERE}/migrate-vm.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2', want '$3')"; fi; }

if [[ ! -r /home/tappaas/bin/common-install-routines.sh ]]; then
    echo "SKIP: /home/tappaas/bin/common-install-routines.sh not present"
    echo "Results: 0 passed, 0 failed"
    exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/migrate-vm-test.XXXXXX")"
trap 'rm -rf "${W}"' EXIT

# ── Stub cluster ─────────────────────────────────────────────────────
# Called as: stub <node_fqdn> <remote command>. Logs every command to $D/log and
# mutates $D state. `qm migrate` records the VM's status AT THAT MOMENT, which is
# what the sequencing assertions below read.
cat > "${W}/stub" <<'STUB'
#!/usr/bin/env bash
D="${MV_TEST_DIR}"
cmd="$2"
rd(){ cat "$D/$1" 2>/dev/null || echo "${2:-}"; }
echo "${cmd}" >> "$D/log"

# Advance any pending CRM transition by one tick.
target="$(rd pending_state)"
if [[ -n "$target" ]]; then
    n="$(rd pending_count 0)"
    if [[ "$n" -le 0 ]]; then
        echo "$target" > "$D/ha_state"
        [[ "$target" == stopped ]] && echo stopped > "$D/vm_status"
        [[ "$target" == started ]] && echo running > "$D/vm_status"
        : > "$D/pending_state"
    else
        echo $((n - 1)) > "$D/pending_count"
    fi
fi

case "$cmd" in
    "ha-manager status")
        echo "quorum OK"
        echo "master tappaas1 (active, Mon Aug 17 12:00:00 2026)"
        # A decoy whose id CONTAINS the one under test, listed first: an
        # unanchored grep answers with this line instead of the real service.
        echo "service vm:1300 (tappaas3, error)"
        [[ -n "$(rd ha_rid)" ]] && echo "service $(rd ha_rid) ($(rd node), $(rd ha_state))"
        ;;
    "ha-manager set "*"--state stopped")
        echo request_stop > "$D/ha_state"; echo stopped > "$D/pending_state"
        rd crm_delay 0 > "$D/pending_count" ;;
    "ha-manager set "*"--state started")
        echo request_start > "$D/ha_state"; echo started > "$D/pending_state"
        rd crm_delay 0 > "$D/pending_count" ;;
    "ha-manager remove "*)      : > "$D/ha_rid" ;;
    "ha-manager add "*)         echo "vm:$(rd vmid)" > "$D/ha_rid"; echo started > "$D/ha_state" ;;
    "pvesh get /cluster/ha/rules"*) echo "[]" ;;
    "pvesh delete /cluster/ha/rules"*|"pvesh create /cluster/ha/rules"*) : ;;
    "pvesh get /cluster/resources"*)
        printf '[{"vmid":%s,"type":"qemu","status":"%s","node":"%s"}]' \
            "$(rd vmid 130)" "$(rd vm_status)" "$(rd node)" ;;
    "qm shutdown "*)
        # graceful_fails=1 models a guest that ignores ACPI: returns non-zero
        # and leaves the VM running, so the caller must escalate.
        [[ "$(rd graceful_fails 0)" == "1" ]] && exit 1
        echo stopped > "$D/vm_status" ;;
    "qm stop "*)  echo stopped > "$D/vm_status" ;;
    "qm start "*)
        # start_fails=1 models a start that is accepted but never runs.
        [[ "$(rd start_fails 0)" == "1" ]] || echo running > "$D/vm_status" ;;
    "qm migrate "*)
        echo "MIGRATE-WHILE-$(rd vm_status)" >> "$D/log"
        [[ "$(rd migrate_fails 0)" == "1" ]] && exit 1
        printf '%s' "$(rd target)" > "$D/node" ;;
    "true") : ;;
    *) exit 1 ;;
esac
exit 0
STUB
chmod +x "${W}/stub"

# Reset the stubbed cluster. Args: <ha_rid|""> <ha_state> <vm_status> [crm_delay]
setup() {
    export MV_TEST_DIR="${W}/state"
    rm -rf "${MV_TEST_DIR}"; mkdir -p "${MV_TEST_DIR}"
    printf '%s' "$1"        > "${MV_TEST_DIR}/ha_rid"
    printf '%s' "$2"        > "${MV_TEST_DIR}/ha_state"
    printf '%s' "$3"        > "${MV_TEST_DIR}/vm_status"
    printf '%s' "${4:-0}"   > "${MV_TEST_DIR}/crm_delay"
    printf '130'            > "${MV_TEST_DIR}/vmid"
    printf 'tappaas1'       > "${MV_TEST_DIR}/node"
    printf 'tappaas2'       > "${MV_TEST_DIR}/target"
    : > "${MV_TEST_DIR}/log"
}
log(){ cat "${MV_TEST_DIR}/log" 2>/dev/null; }
logged(){ grep -qF "$1" "${MV_TEST_DIR}/log" 2>/dev/null; }

# Source migrate-vm.sh with a stubbed ssh and lib exec, then run one function.
# Runs in a subshell so migrate-vm.sh's die (exit 1) does not kill the suite.
run_migrate() {
    (
        export TAPPAAS_HAVM_EXEC="${W}/stub"
        export HAVM_POLL_INTERVAL=1
        # Pre-define tappaas_ssh()/tappaas_ssh_identity() from THIS worktree
        # (ADR-018, #518/#519/#520) before MIGRATE's own sourcing of the
        # deployed /home/tappaas/bin/common-install-routines.sh — matching
        # test-common-install-routines.sh/test-ha-vm-lib.sh's own convention
        # of testing worktree code, not whatever is currently deployed. The
        # stale deployed copy re-sourced below redefines info/warn/error but
        # has no tappaas_ssh of its own to clobber these with.
        # shellcheck source=../../lib/common-install-routines.sh disable=SC1091
        . "${HERE}/../../lib/common-install-routines.sh" "" >/dev/null 2>&1
        # shellcheck source=migrate-vm.sh disable=SC1091
        . "${MIGRATE}" >/dev/null 2>&1
        # Mock ssh — must tolerate leading -o/-i flags: tappaas_ssh() puts
        # them before the host, unlike the plain `ssh root@host cmd` this
        # mock originally only had to parse.
        ssh() {
            local host=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -o|-i) shift 2 ;;
                    -*) shift ;;
                    *) host="$1"; shift; break ;;
                esac
            done
            "${W}/stub" "${host#root@}" "$*"
        }
        # The poll LOOPS are what is under test, not wall-clock patience: a
        # no-op sleep runs a full 120s timeout budget in milliseconds while the
        # stub still advances one CRM tick per command, so the "waits it out"
        # and "gives up" paths are both exercised at real iteration counts.
        sleep() { :; }
        "$@"
    )
}

# ── HA-managed offline migration ─────────────────────────────────────
# crm_delay=3: the CRM acts three polls after being asked. The migration must
# wait it out — the old code polled, gave up quietly, and relied on a later check.
setup "vm:130" started running 3
if run_migrate do_offline_migration 130 tappaas1 tappaas2 testvm >/dev/null 2>&1; then ok
else no "offline migration should succeed against a slow CRM"; fi
if logged "ha-manager set vm:130 --state stopped"; then ok; else no "HA stop should go through the CRM"; fi
# The invariant: the VM was stopped at the moment qm migrate ran.
check "#434: migrate issued only after the VM stopped" \
    "$(log | grep -c 'MIGRATE-WHILE-stopped')" "1"
check "#434: migrate never issued while running" \
    "$(log | grep -c 'MIGRATE-WHILE-running')" "0"
# Order: removed from HA after the stop, re-added on the target after the start.
if logged "ha-manager remove vm:130"; then ok; else no "VM should be removed from HA before migrating"; fi
if logged "ha-manager add vm:130 --state started"; then ok; else no "HA should be restored on the target"; fi

# ── A stop that never completes aborts the migration ─────────────────
setup "vm:130" started running 9999
if run_migrate do_offline_migration 130 tappaas1 tappaas2 testvm >/dev/null 2>&1; then
    no "offline migration must fail when the VM never stops"
else ok; fi
if logged "qm migrate"; then no "#434: must not migrate a VM that never stopped"; else ok; fi
if logged "ha-manager remove vm:130"; then no "must not leave HA before the stop is confirmed"; else ok; fi

# ── Non-HA: a failed graceful shutdown escalates and is confirmed ────
setup "" "" running
printf '1' > "${MV_TEST_DIR}/graceful_fails"
if run_migrate do_offline_migration 130 tappaas1 tappaas2 testvm >/dev/null 2>&1; then ok
else no "offline migration should recover from a failed graceful shutdown"; fi
if logged "qm shutdown 130 --timeout 90"; then ok; else no "graceful shutdown should be attempted first"; fi
if logged "qm stop 130"; then ok; else no "a failed graceful shutdown must escalate to a hard stop"; fi
check "migrate ran only once the hard stop took effect" \
    "$(log | grep -c 'MIGRATE-WHILE-stopped')" "1"

# ── A VM that does not come up on the target fails the migration ─────
setup "" "" running
printf '1' > "${MV_TEST_DIR}/start_fails"
if run_migrate do_offline_migration 130 tappaas1 tappaas2 testvm >/dev/null 2>&1; then
    no "migration must fail when the VM does not run on the target"
else ok; fi
if logged "qm start 130"; then ok; else no "start should have been attempted"; fi

# ── HA detection reports the state, not the node ─────────────────────
# The old parser printed field 3 of `service vm:130 (tappaas1, started)` — the
# node, "(tappaas1," — and its unanchored grep matched the vm:1300 decoy first.
setup "vm:130" started running 0
out="$(run_migrate try_live_migration 130 tappaas1 tappaas2 2>&1)"
if grep -q 'state: started' <<< "${out}"; then ok; else no "HA state should be reported as 'started' (got: $(grep -o 'state: [^)]*' <<< "${out}" | head -1))"; fi
if grep -q 'state: (tappaas' <<< "${out}"; then no "HA state must not be the node name"; else ok; fi
if grep -q 'state: error' <<< "${out}"; then no "vm:1300 decoy must not answer for vm:130"; else ok; fi

# A VM that is genuinely not HA-managed must not be treated as HA-managed just
# because the decoy line exists.
setup "" "" running
out="$(run_migrate try_live_migration 130 tappaas1 tappaas2 2>&1)"
if grep -q 'HA-managed' <<< "${out}"; then no "non-HA VM must not be reported HA-managed"; else ok; fi
if logged "ha-manager remove"; then no "non-HA VM must not be removed from HA"; else ok; fi

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
