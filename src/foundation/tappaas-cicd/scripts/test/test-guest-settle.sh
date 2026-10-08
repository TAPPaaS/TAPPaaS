#!/usr/bin/env bash
#
# test-guest-settle.sh — a guest's update waits for it to settle, and the verify
# step does not race a boot (#753).
#
# coturn's update on hrossen (2026-10-01) failed its `cluster:vm` SSH check
# seconds after its OS update, and rolled back. Two halves, lifted out of their
# scripts and run against a stubbed ssh that replays a guest's answers:
#   update-os.sh      wait_for_guest_settled — until systemd has no job queued,
#                     twice in a row, bounded
#   cluster:vm        ssh_settle_check — SSH retried for a bounded time, the
#   test-service.sh   failure naming ssh's own error
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UOS="${HERE}/../../manager/health-manager/update-os.sh"
TSV="${HERE}/../../../cluster/services/vm/test-service.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
[[ -f "${UOS}" && -f "${TSV}" ]] || { echo "update-os.sh / test-service.sh not found — cannot run here."; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/settle.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
SETTLE="$(sed -n '/^wait_for_guest_settled() {/,/^}/p' "${UOS}")"
CHECK="$(sed -n '/^ssh_settle_check() {/,/^}/p' "${TSV}")"
ck "wait_for_guest_settled extracts" "yes" "$([[ -n "${SETTLE}" ]] && echo yes || echo no)"
ck "ssh_settle_check extracts" "yes" "$([[ -n "${CHECK}" ]] && echo yes || echo no)"

# The guest's answers, one per ssh call: a number is `systemctl list-jobs | wc -l`,
# "down" an ssh failure, "ok" a successful login.
replay() { printf '%s\n' "$@" > "${T}/answers"; : > "${T}/calls"; }
run_settle() {   # $1 = max seconds; prints rc and the number of ssh calls
    T="${T}" MAX="$1" bash -c '
        debug(){ :; }; warn(){ :; }; sleep(){ :; }
        ssh() { echo x >> "${T}/calls"; local a; a="$(head -1 "${T}/answers")"; sed -i.b 1d "${T}/answers"
                [[ "${a:-0}" == down ]] && return 255; echo "${a:-0}"; }
        '"${SETTLE}"'
        wait_for_guest_settled 10.0.0.9 "${MAX}"; echo "rc=$? calls=$(wc -l < "${T}/calls" | tr -d " ")"'
}
replay 0 0
ck "a quiet guest: settled after two empty polls" "rc=0 calls=2" "$(run_settle 90)"
replay 3 down 1 0 2 0 0
ck "jobs, a dropped connection, a job again: waits until two empty polls in a row" "rc=0 calls=7" "$(run_settle 90)"
replay 4 4 4 4 4 4 4 4 4 4
ck "a guest that never settles: bounded, rc 1, never forever" "rc=1 calls=3" "$(run_settle 9)"

run_check() {   # $1 = SSH_SETTLE_MAX; prints rc, waited, and the error
    T="${T}" MAX="$1" bash -c '
        sleep(){ :; }
        SSH_OPTS=""; SSH_USER=tappaas; VM_HOST=coturn.dmz.internal; SSH_SETTLE_MAX="${MAX}"
        ssh() { local a; a="$(head -1 "${T}/answers")"; sed -i.b 1d "${T}/answers"
                [[ "${a}" == ok ]] && return 0; echo "ssh: connect to host ${VM_HOST} port 22: Connection refused" >&2; return 255; }
        '"${CHECK}"'
        SSH_ERR=""; SSH_WAITED=0
        ssh_settle_check; echo "rc=$? waited=${SSH_WAITED} err=${SSH_ERR}"'
}
replay ok
ck "SSH up at once: passes without waiting" "rc=0 waited=0 err=" "$(run_check 60)"
replay down down ok
ck "sshd restarting (two refusals): passes after 10s instead of reporting drift" "rc=0 waited=10 err=" "$(run_check 60)"
replay down down down down
ck "never up: fails at its bound, naming ssh's own error" "rc=1 waited=0 err=ssh: connect to host coturn.dmz.internal port 22: Connection refused" "$(run_check 10)"

ck "update-os waits for the guest to settle after the reboot and after a switch" "2" \
   "$(grep -c 'wait_for_guest_settled "${vm_ip}" 90' "${UOS}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
