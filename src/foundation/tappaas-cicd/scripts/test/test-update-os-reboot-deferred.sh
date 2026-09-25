#!/usr/bin/env bash
#
# test-update-os-reboot-deferred.sh — a NixOS guest's reboot that update-os.sh
# does not take is reported as a DEFERRED: line, and --allow-disruption
# authorizes it (#730, ADR-020 D8).
#
# Before, all three skip paths — automaticReboot=false, a VM locked by a backup
# (#686), the controller updating itself — only printed a warning, so a guest
# waiting on a reboot (since #728: possibly on a whole staged release move) was
# visible only in the journal of the run that skipped it.
#
# The reboot block is lifted out of update-os.sh and run against a stubbed ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck()    { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin()  { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
ckout() { if [[ "$3" != *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (unexpected '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/reboot-deferred.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# From the pending-reboot text to the end of the function.
awk '/^    local _pending=/{f=1} f&&/^}$/{exit} f{print}' "${SRC}" > "${TMP}/block.sh"
ck "the reboot block extracts" "yes" \
   "$(grep -q 'automatic_reboot_enabled' "${TMP}/block.sh" && grep -q 'wait_for_module_ready' "${TMP}/block.sh" && echo yes || echo no)"

# run <automaticReboot on|off> <allow 0|1> <reboot ok|locked|fail> <self 0|1> <staged 0|1>
# Prints: <exit>|reboots=<n>|deferred=<n>; the log is in ${TMP}/out.
run() {
    GATE="$1" ALLOW="$2" REBOOT="$3" SELF="$4" STAGED="$5" T="${TMP}" bash -c '
        set -euo pipefail
        : > "${T}/calls"
        info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; error(){ echo "ERROR $*"; }
        die(){ error "$@"; exit 1; }; debug(){ :; }
        update_ssh_known_hosts(){ :; }; wait_for_ssh(){ return 0; }; wait_for_module_ready(){ return 0; }
        wait_for_vm_unlock(){ return 0; }
        vm_lock_holder(){ [[ "${REBOOT}" == locked ]] && echo backup || true; }
        automatic_reboot_enabled(){ [[ "${GATE}" == on ]]; }
        hostname(){ [[ "${SELF}" == 1 ]] && echo guest || echo tappaas-cicd; }
        ssh() {
            case "${*: -1}" in
                "qm reboot"*) echo reboot >> "${T}/calls"; [[ "${REBOOT}" == ok ]] ;;
                *) return 0 ;;
            esac
        }
        [[ "${ALLOW}" == 1 ]] && export TAPPAAS_ALLOW_DISRUPTION=1
        vm_ip=10.2.0.9 vmname=guest vmid=310 node=tappaas2 MGMT=mgmt
        staged="${STAGED}" _move="25.11 26.05"
        f() { '"$(cat "${TMP}/block.sh")"'
        }
        f
    ' > "${TMP}/out" 2>&1
    local rc=$?
    echo "${rc}|reboots=$(grep -c reboot "${TMP}/calls")|deferred=$(grep -c 'DEFERRED:' "${TMP}/out")"
}

echo "── automaticReboot on: rebooted, nothing deferred (unchanged) ──"
ck "gate on, reboot works" "0|reboots=1|deferred=0" "$(run on 0 ok 0 0)"

echo "── automaticReboot off: deferred, and reported ──"
ck "gate off: no reboot, one DEFERRED" "0|reboots=0|deferred=1" "$(run off 0 ok 0 0)"
ckin "  …a line the sweep collects" "DEFERRED: guest reboot to take the new NixOS generation needs a disruptive change that is not authorized" "$(cat "${TMP}/out")"
ckin "  …and it says how to authorize it" "module-manager module update guest --allow-disruption" "$(cat "${TMP}/out")"

echo "── --allow-disruption authorizes the reboot with the gate off (ADR-020 D8) ──"
ck "gate off + TAPPAAS_ALLOW_DISRUPTION=1: rebooted" "0|reboots=1|deferred=0" "$(run off 1 ok 0 0)"

echo "── a backup lock postpones the reboot: deferred, not failed (#686) ──"
ck "locked: exit 0, one DEFERRED" "0|reboots=1|deferred=1" "$(run on 0 locked 0 0)"
ckin "  …naming the holder" "the VM was locked (backup)" "$(cat "${TMP}/out")"
ck "an unexplained reboot failure still dies" "1|reboots=1|deferred=0" "$(run on 0 fail 0 0)"

echo "── the controller never reboots itself, even when authorized ──"
ck "self, gate on: no reboot, one DEFERRED" "0|reboots=0|deferred=1" "$(run on 0 ok 1 0)"
ck "self, allow-disruption: still no reboot" "0|reboots=0|deferred=1" "$(run on 1 ok 1 0)"
ckin "  …'reboot it under supervision'" "it runs this update, reboot it under supervision" "$(cat "${TMP}/out")"

echo "── a staged release move says so in the DEFERRED line (#728) ──"
run off 0 ok 0 1 >/dev/null
ckin "staged: names the move" "DEFERRED: guest reboot to take the staged release move 25.11 -> 26.05" "$(cat "${TMP}/out")"
ckout "  …and not 'the new NixOS generation'" "take the new NixOS generation" "$(cat "${TMP}/out")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
