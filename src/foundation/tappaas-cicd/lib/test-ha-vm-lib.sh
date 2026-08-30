#!/usr/bin/env bash
#
# test-ha-vm-lib.sh — unit tests for the HA-aware stop/start helpers (lib/ha-vm-lib.sh).
#
# Runs entirely against a stubbed cluster (TAPPAAS_HAVM_EXEC) — no ssh, no node,
# no VM. The stub models the thing that caused #434: a CRM that does not act on
# a queued command immediately, but N polls later.
#
# Covers:
#   - the #434 regression itself: a stop against a slow CRM is WAITED OUT, not
#     assumed after a fixed sleep, and the VM is really stopped on return;
#   - a CRM that never converges fails the stop (non-zero) instead of reporting
#     success — the whole point of the issue;
#   - a failed qm/pct stop is propagated, not discarded (`2>/dev/null || true`);
#   - start puts the HA requested state back to 'started', without which the CRM
#     converges the resource straight back down;
#   - LXC resources are addressed as ct:<id>, not vm:<id>.
#
# Usage: test-ha-vm-lib.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }   # silence the lib's progress in tests
# shellcheck source=ha-vm-lib.sh
. "${HERE}/ha-vm-lib.sh"

# shellcheck disable=SC2034  # read by the sourced lib, not by this file
HAVM_POLL_INTERVAL=1                        # keep the suite sub-second

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2', want '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ha-vm-lib-test.XXXXXX")"
trap 'rm -rf "${W}"' EXIT

# ── Stub cluster ─────────────────────────────────────────────────────
# Called as: stub <node_fqdn> <remote command>. State lives in $HAVM_TEST_DIR:
#   rid           HA resource id, or empty for a resource that is not HA-managed
#   ha_state      current HA service state
#   vm_status     current cluster-resource status
#   crm_delay     polls the CRM takes to act on a queued command (the #434 race)
#   fail_cmd      substring of a command the stub should exit 1 on
# A queued `ha-manager set` records a pending target; each subsequent call ticks
# it down and only then applies it — exactly the lag the old `sleep 3` outran.
cat > "${W}/stub" <<'STUB'
#!/usr/bin/env bash
D="${HAVM_TEST_DIR}"
cmd="$2"
rd(){ cat "$D/$1" 2>/dev/null || echo "${2:-}"; }

fc="$(rd fail_cmd)"
[[ -n "$fc" && "$cmd" == *"$fc"* ]] && exit 1

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
        hs="$(rd ha_state)"
        echo "quorum OK"
        echo "master tappaas1 (active, Mon Aug 17 12:00:00 2026)"
        # No service line at all when the resource is not HA-managed.
        [[ -n "$(rd rid)" ]] && echo "service $(rd rid) (tappaas1, ${hs})"
        ;;
    "ha-manager set "*"--state stopped")
        echo request_stop > "$D/ha_state"
        echo stopped     > "$D/pending_state"
        rd crm_delay 0   > "$D/pending_count"
        ;;
    "ha-manager set "*"--state started")
        echo request_start > "$D/ha_state"
        echo started       > "$D/pending_state"
        rd crm_delay 0     > "$D/pending_count"
        ;;
    "pvesh get /cluster/resources"*)
        printf '[{"vmid":%s,"type":"%s","status":"%s"}]' \
            "$(rd vmid 130)" "$(rd vtype qemu)" "$(rd vm_status)"
        ;;
    "qm stop "*|"pct stop "*)   echo stopped > "$D/vm_status" ;;
    "qm start "*|"pct start "*) echo running > "$D/vm_status" ;;
    *) exit 1 ;;
esac
exit 0
STUB
chmod +x "${W}/stub"
export TAPPAAS_HAVM_EXEC="${W}/stub"

# Reset the stubbed cluster. Args: <rid|""> <ha_state> <vm_status> [crm_delay] [vmid] [vtype]
setup() {
    export HAVM_TEST_DIR="${W}/state"
    rm -rf "${HAVM_TEST_DIR}"; mkdir -p "${HAVM_TEST_DIR}"
    printf '%s' "$1" > "${HAVM_TEST_DIR}/rid"
    printf '%s' "$2" > "${HAVM_TEST_DIR}/ha_state"
    printf '%s' "$3" > "${HAVM_TEST_DIR}/vm_status"
    printf '%s' "${4:-0}"    > "${HAVM_TEST_DIR}/crm_delay"
    printf '%s' "${5:-130}"  > "${HAVM_TEST_DIR}/vmid"
    printf '%s' "${6:-qemu}" > "${HAVM_TEST_DIR}/vtype"
    : > "${HAVM_TEST_DIR}/pending_state"
    : > "${HAVM_TEST_DIR}/fail_cmd"
}
state(){ cat "${HAVM_TEST_DIR}/$1" 2>/dev/null; }

N="tappaas1.mgmt.internal"

# ── Resource ids ─────────────────────────────────────────────────────
check "resource id (qemu)" "$(havm_resource_id qemu 130)" "vm:130"
check "resource id (lxc)"  "$(havm_resource_id lxc 200)"  "ct:200"

# ── HA state parsing ─────────────────────────────────────────────────
setup "vm:130" started running
check "ha state parsed from ha-manager status" "$(havm_ha_state "$N" vm:130)" "started"
if havm_is_ha_managed "$N" vm:130; then ok; else no "vm:130 should read as HA-managed"; fi
# A resource id that is not in the status output must read as not-HA-managed,
# NOT as some other service's state.
check "unknown resource has no HA state" "$(havm_ha_state "$N" vm:999)" ""
if havm_is_ha_managed "$N" vm:999; then no "vm:999 should not read as HA-managed"; else ok; fi

setup "" "" running
if havm_is_ha_managed "$N" vm:130; then no "non-HA VM should not read as HA-managed"; else ok; fi
check "cluster status read" "$(havm_status "$N" 130)" "running"

# ── #434: the stop is waited out, not assumed ────────────────────────
# crm_delay=4 means the CRM needs four polls to act — the old code slept a fixed
# 3s and moved on regardless. havm_stop must return only once it is really stopped.
setup "vm:130" started running 4
if havm_stop "$N" 130 qemu 60; then ok; else no "havm_stop should succeed against a slow CRM"; fi
check "#434: VM actually stopped on return" "$(state vm_status)" "stopped"
check "#434: HA settled on stopped"         "$(state ha_state)"  "stopped"

# ── A CRM that never converges FAILS the stop ────────────────────────
# The heart of the issue: no success is reported for a transition that did not happen.
setup "vm:130" started running 999
if havm_stop "$N" 130 qemu 3; then no "havm_stop must fail when the CRM never stops the VM"; else ok; fi
check "VM still running after the failed stop" "$(state vm_status)" "running"

check "#434: caller told the stop went through HA" "${HAVM_LAST_STOP_WAS_HA}" "1"

# The abort flag must be set even when the stop then TIMES OUT — that is exactly
# when the caller has to hand the resource back, or HA holds it down (#434).
setup "vm:130" started running 999
havm_stop "$N" 130 qemu 3
check "abort flag set after a timed-out HA stop" "${HAVM_LAST_STOP_WAS_HA}" "1"

# ── A failed qm/pct stop is propagated, not discarded ────────────────
setup "" "" running
printf '%s' "qm stop" > "${HAVM_TEST_DIR}/fail_cmd"
if havm_stop "$N" 130 qemu 3; then no "havm_stop must fail when qm stop fails"; else ok; fi
check "non-HA stop leaves the abort flag clear" "${HAVM_LAST_STOP_WAS_HA}" "0"

# ── An unreadable cluster is not assumed to be non-HA ────────────────
# Folding "cannot tell" into "not HA-managed" would send the stop down the raw qm
# path and reinstate the race. Both stop and start must refuse instead.
setup "vm:130" started running
printf '%s' "ha-manager status" > "${HAVM_TEST_DIR}/fail_cmd"
if havm_stop "$N" 130 qemu 3;  then no "havm_stop must fail when the HA probe fails";  else ok; fi
if havm_start "$N" 130 qemu 3; then no "havm_start must fail when the HA probe fails"; else ok; fi
check "no stop was issued on an unreadable cluster" "$(state vm_status)" "running"
check "probe rc distinguishes 'cannot tell'" \
    "$(havm_ha_probe "$N" vm:130 >/dev/null; echo $?)" "2"

setup "" "" running
check "probe rc distinguishes 'not HA-managed'" \
    "$(havm_ha_probe "$N" vm:130 >/dev/null; echo $?)" "1"

# ── Already stopped is a no-op success ───────────────────────────────
setup "vm:130" stopped stopped
if havm_stop "$N" 130 qemu 3; then ok; else no "havm_stop on an already-stopped VM should succeed"; fi

# ── Start restores the HA requested state ────────────────────────────
# Without the `ha-manager set --state started`, the CRM keeps converging on the
# 'stopped' the stop asked for and the VM goes straight back down (#434).
setup "vm:130" stopped stopped 2
if havm_start "$N" 130 qemu 60; then ok; else no "havm_start should succeed against a slow CRM"; fi
check "HA requested state back to started" "$(state ha_state)"  "started"
check "VM running on return"               "$(state vm_status)" "running"

setup "vm:130" stopped stopped 999
if havm_start "$N" 130 qemu 3; then no "havm_start must fail when the VM never starts"; else ok; fi

# ── Non-HA start goes through qm ─────────────────────────────────────
setup "" "" stopped
if havm_start "$N" 130 qemu 10; then ok; else no "havm_start should start a non-HA VM"; fi
check "non-HA VM running" "$(state vm_status)" "running"

# ── LXC is addressed as ct:<id> ──────────────────────────────────────
setup "ct:200" started running 2 200 lxc
if havm_is_ha_managed "$N" "$(havm_resource_id lxc 200)"; then ok; else no "ct:200 should read as HA-managed"; fi
if havm_stop "$N" 200 lxc 60; then ok; else no "havm_stop should stop an HA-managed container"; fi
check "container stopped" "$(state vm_status)" "stopped"

# ── Release hand-back ────────────────────────────────────────────────
# Fire-and-forget by design (it runs on abort paths, where nothing is left to
# wait): it must request 'started' and let the CRM converge, never block or fail.
setup "vm:130" stopped stopped 0
havm_release_ha_stop "$N" vm:130
check "hand-back requests started" "$(state ha_state)" "request_start"
havm_wait_ha_state "$N" vm:130 started 5
check "CRM converges the hand-back" "$(state ha_state)" "started"

# It must stay silent-and-successful even when the cluster refuses the command.
setup "vm:130" stopped stopped 0
printf '%s' "ha-manager set" > "${HAVM_TEST_DIR}/fail_cmd"
if havm_release_ha_stop "$N" vm:130; then ok; else no "hand-back must not fail its caller"; fi

# ── The single `ha-manager status` parser ────────────────────────────
# Four hand-rolled parsers were replaced by this one (snapshot-vm, migrate-vm,
# reboot-node-lib, and this lib), so it has to cope with everything they saw:
# non-service lines, ids that are prefixes of other ids, and node names that are
# prefixes of other node names.
cat > "${W}/parser-stub" <<'PSTUB'
#!/usr/bin/env bash
[[ "$2" == "ha-manager status" ]] || exit 1
cat <<'OUT'
quorum OK
master tappaas1 (active, Mon Aug 17 12:00:00 2026)
lrm tappaas1 (idle, Mon Aug 17 12:00:00 2026)
service vm:1300 (tappaas3, error)
service vm:130 (tappaas1, started)
service vm:140 (tappaas10, migrate)
service ct:200 (tappaas1, stopped)
OUT
PSTUB
chmod +x "${W}/parser-stub"

# Point the exec seam at the parser stub for this block only. NOT a subshell:
# check() increments counters, and a subshell would discard them — the failures
# would print but the suite would still exit 0.
TAPPAAS_HAVM_EXEC="${W}/parser-stub"

    check "services: only service lines, as 'sid node state'" \
        "$(havm_ha_services "$N" | head -1)" "vm:1300 tappaas3 error"
    check "services: quorum/master/lrm lines are skipped" \
        "$(havm_ha_services "$N" | wc -l)" "4"

    # Exact id match: vm:1300 is listed FIRST and vm:13 does not exist. A
    # substring match answers 'error' for both.
    check "state: exact id, not a prefix match" "$(havm_ha_state "$N" vm:130)"  "started"
    check "state: the longer id keeps its own state" "$(havm_ha_state "$N" vm:1300)" "error"
    check "state: a shorter id matches nothing" "$(havm_ha_state "$N" vm:13)" ""
    check "state: containers are addressable" "$(havm_ha_state "$N" ct:200)" "stopped"

    # Exact node match: tappaas1 must not sweep in tappaas10's service.
    check "on-node: exact node, not a prefix match" \
        "$(havm_ha_services_on_node "$N" tappaas1 | awk '{print $1}' | tr '\n' ' ')" \
        "vm:130 ct:200 "
    check "on-node: filtered by state" \
        "$(havm_ha_services_on_node "$N" tappaas1 started | awk '{print $1}')" "vm:130"
    check "on-node: no match is empty, not an error" \
        "$(havm_ha_services_on_node "$N" tappaas2)" ""

    # started/stopped rest; error and migrate do not.
    check "unsettled: only transitional services" \
        "$(havm_ha_unsettled "$N" | tr '\n' ' ')" "vm:1300=error vm:140=migrate "

TAPPAAS_HAVM_EXEC="${W}/stub"   # back to the state-machine stub

# TAPPAAS_HA_STATUS_FILE feeds a canned listing instead of querying a node —
# check-ha-health.sh's offline test hook, which now runs through this parser.
cat > "${W}/canned" <<'CANNED'
quorum OK
lrm tappaas1 (idle, Mon Aug 17 12:00:00 2026)
service vm:210 (tappaas2, migrate)
service vm:220 (tappaas1, started)
CANNED
setup "" "" running
printf '%s' "ha-manager status" > "${HAVM_TEST_DIR}/fail_cmd"   # exec would fail
# shellcheck disable=SC2034  # read by the sourced lib, not by this file
TAPPAAS_HA_STATUS_FILE="${W}/canned"
check "file hook: parsed without touching the cluster" \
    "$(havm_ha_services "$N" | tr '\n' ';')" "vm:210 tappaas2 migrate;vm:220 tappaas1 started;"
check "file hook: unsettled works off the canned listing" \
    "$(havm_ha_unsettled "$N")" "vm:210=migrate"
check "file hook: rc 1 when the file is unreadable" \
    "$(TAPPAAS_HA_STATUS_FILE="${W}/nope" havm_ha_services "$N" >/dev/null 2>&1; echo $?)" "1"

# Empty output is a failed query, not "no services" — check-ha-health.sh reports
# it as undetermined (exit 1), and must keep doing so.
: > "${W}/empty"
check "empty status is rc 1, not an empty service list" \
    "$(TAPPAAS_HA_STATUS_FILE="${W}/empty" havm_ha_services "$N" >/dev/null 2>&1; echo $?)" "1"
check "empty status makes the probe 'cannot tell', not 'not HA'" \
    "$(TAPPAAS_HA_STATUS_FILE="${W}/empty" havm_ha_probe "$N" vm:130 >/dev/null 2>&1; echo $?)" "2"

# A cluster with quorum but no HA services: readable (rc 0) and empty.
printf 'quorum OK\nlrm tappaas1 (idle, x)\n' > "${W}/noservices"
check "no HA services is rc 0 with no output" \
    "$(TAPPAAS_HA_STATUS_FILE="${W}/noservices" havm_ha_services "$N" >/dev/null 2>&1; echo $?)" "0"
unset TAPPAAS_HA_STATUS_FILE

# A failed status query is rc 1 with no output — never "there are no services".
setup "vm:130" started running
printf '%s' "ha-manager status" > "${HAVM_TEST_DIR}/fail_cmd"
check "services: rc 1 when the query fails" \
    "$(havm_ha_services "$N" >/dev/null 2>&1; echo $?)" "1"
check "unsettled: rc 1 when the query fails" \
    "$(havm_ha_unsettled "$N" >/dev/null 2>&1; echo $?)" "1"

# ── Standalone sourcing under errexit ────────────────────────────────
# Everything above runs with info/warn/error stubbed, which would hide a broken
# logging fallback. Source the lib in a clean `set -euo pipefail` shell that
# defines none of them: `info` is ALSO a real binary (texinfo), so a
# `command -v info`-style guard succeeds without any function existing and every
# info call runs the reader instead — failing the first one.
setup "vm:130" started running 2
if bash -c '
        set -euo pipefail
        . "$1/ha-vm-lib.sh"
        HAVM_POLL_INTERVAL=1
        havm_stop  tappaas1.mgmt.internal 130 qemu 30
        havm_start tappaas1.mgmt.internal 130 qemu 30
   ' _ "${HERE}" >/dev/null 2>&1; then
    ok
else
    no "lib must work standalone under set -e with no caller-supplied logging functions"
fi

# ── havm_exec()'s real ssh path (ADR-018, #518/#519/#520) ────────────
# Every test above runs through TAPPAAS_HAVM_EXEC, which bypasses havm_exec()'s
# real `ssh` branch entirely — none of them would catch a regression in its
# explicit -i/IdentitiesOnly=yes. Exercise that branch directly: unset the
# stub seam, stub the real `ssh` binary via PATH instead, and capture argv.
(
    unset TAPPAAS_HAVM_EXEC
    # shellcheck source=common-install-routines.sh disable=SC1091
    . "${HERE}/common-install-routines.sh" ""   # tappaas_ssh_identity()
    STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/havm-exec-ssh-test.XXXXXX")"
    trap 'rm -rf "${STUBDIR}"' EXIT
    cat > "${STUBDIR}/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
    chmod +x "${STUBDIR}/ssh"
    PATH="${STUBDIR}:${PATH}" havm_exec tappaas1.mgmt.internal "true"
) > "${W}/havm_exec_ssh_argv" 2>/dev/null
check "havm_exec: passes explicit -i" \
    "$(grep -cx -- '-i' "${W}/havm_exec_ssh_argv")" "1"
check "havm_exec: passes IdentitiesOnly=yes" \
    "$(grep -cx -- 'IdentitiesOnly=yes' "${W}/havm_exec_ssh_argv")" "1"

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
