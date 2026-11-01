#!/usr/bin/env bash
#
# test-simulate.sh — hermetic tests for the TAPPAAS_SIMULATE=1 gate in
# common-install-routines.sh: a command on lib/simulate-mutators.txt is logged
# and skipped (exit 0, empty stdout), a read runs, also behind sudo, env,
# timeout, ssh and `bash -c`. The real commands are stubs on PATH that leave a
# mark, so nothing here touches the machine.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

d="$(mktemp -d)"
trap 'rm -rf "${d}"' EXIT
mkdir -p "${d}/bin" "${d}/config"
for c in qm pct pvesh zfs zpool systemctl nixos-rebuild; do
    printf '#!/bin/sh\necho "$0 $*" >> "%s/ran"\necho real-output\n' "${d}" > "${d}/bin/${c}"
done
# A stub ssh and sudo run what they are handed, as the real ones would.
printf '#!/bin/sh\necho "ssh $*" >> "%s/ran"\necho real-output\n' "${d}" > "${d}/bin/ssh"
printf '#!/bin/sh\nexec "$@"\n' > "${d}/bin/sudo"
chmod +x "${d}/bin/"*
export PATH="${d}/bin:${PATH}"

# <what> <expected: skip|run> <shell line>, each in a fresh shell over the lib.
expect() {
    local want="$2" out err rc=0
    : > "${d}/ran"
    out="$(TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; $3" 2>"${d}/err")" || rc=$?
    err="$(cat "${d}/err")"
    if [[ "${want}" == skip ]]; then
        [[ "${rc}" -eq 0 && -z "${out}" && ! -s "${d}/ran" && "${err}" == *"[simulate] "* ]] \
            && ok "$1: skipped and logged" || bad "$1: rc=${rc} out='${out}' ran='$(cat "${d}/ran")' err='${err}'"
    else
        [[ "${rc}" -eq 0 && "${out}" == *real-output* && -s "${d}/ran" && "${err}" != *"[simulate]"* ]] \
            && ok "$1: ran" || bad "$1: rc=${rc} out='${out}' err='${err}'"
    fi
}

echo "simulate gate:"
expect "qm stop"            skip 'qm stop 100'
expect "pct set"            skip 'pct set 101 -onboot 1'
expect "pvesh create"       skip 'pvesh create /nodes/x/qemu'
expect "zfs snapshot"       skip 'zfs snapshot rpool/x@y'
expect "zpool create"       skip 'zpool create tank sdb'
expect "nixos-rebuild"      skip 'nixos-rebuild switch'
expect "systemctl flag"     skip 'systemctl --no-block restart foo'
expect "sudo qm"            skip 'sudo -n qm destroy 100'
expect "env qm"             skip 'env A=1 qm start 100'
expect "ssh nixos-rebuild"  skip 'ssh -o BatchMode=yes tappaas@guest "sudo nixos-rebuild switch"'
expect "ssh chain"          skip 'ssh root@node "cd /tmp && qm stop 100"'
expect "ssh bash -lc"       skip "ssh root@node \"bash -lc 'zfs destroy a/b'\""
expect "guest helper"       skip 'tappaas_ssh_guest root@node "pct stop 101"'
expect "bash child"         skip "bash -c 'qm stop 100'"
expect "qm status"          run  'qm status 100'
expect "pvesh get"          run  'pvesh get /nodes'
expect "zfs list"           run  'zfs list'
expect "zpool list"         run  'zpool list'
expect "is-active"          run  'systemctl is-active foo'
expect "ssh read"           run  'ssh root@node "qm status 100"'
expect "ssh other"          run  'ssh root@node "uptime"'

# run_with_dots sends the command's stderr to its log.
: > "${d}/ran"
TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; run_with_dots '${d}/log' qm stop 100"
[[ ! -s "${d}/ran" ]] && grep -q '\[simulate\] qm stop 100' "${d}/log" && ok "run_with_dots: skipped and logged" || bad "run_with_dots"

# The config helper: logged, the file untouched.
echo '{"a":1}' > "${d}/config/m.json"
: > "${d}/ran"
err="$(TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; jq_module_write m '.a=2'" 2>&1)"
[[ "$(cat "${d}/config/m.json")" == '{"a":1}' && "${err}" == *"[simulate] write"* ]] \
    && ok "jq_module_write skipped" || bad "jq_module_write: ${err}"

# Off, the same line runs.
: > "${d}/ran"
out="$(CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; qm stop 100" 2>/dev/null)"
[[ "${out}" == real-output ]] && ok "unset: qm stop runs" || bad "unset: '${out}'"

# No list: the script stops, nothing runs.
: > "${d}/ran"
rc=0
err="$(TAPPAAS_SIMULATE=1 TAPPAAS_SIMULATE_MUTATORS="${d}/none" CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' 2>&1; qm status 1" 2>&1)" || rc=$?
[[ "${rc}" -ne 0 && ! -s "${d}/ran" && "${err}" == *"not found: refusing to run"* ]] && ok "no list: refuses" || bad "no list: rc=${rc} ${err}"

printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
