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
for c in qm pct pvesh zfs zpool systemctl nixos-rebuild git curl nix scp; do
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
expect "sudo rm"            skip 'sudo -n rm -rf /var/lib/x'
expect "pct exec"           skip 'pct exec 101 -- hostname'
expect "qm guest exec"      skip 'qm guest exec 100 -- hostname'
expect "scp"                skip 'scp a root@node:/tmp/a'
expect "git -C commit"      skip 'git -C /x -c a=b commit -m y'
expect "git stash push"     skip 'git -C /x stash push -u'
expect "git stash list"     run  'git -C /x stash list'
expect "git log"            run  'git -C /x log'
expect "curl -X POST"       skip 'curl -ks -X POST https://fw/api/x'
expect "curl --data"        skip 'curl --data=a https://fw/api/x'
expect "curl GET"           run  'curl -ks https://fw/api/x'
expect "nix out-link"       skip 'nix build .#x --out-link /y'
expect "nix build"          run  'nix build .#x'
expect "ssh script"         skip 'ssh root@node "/root/tappaas/x.sh arg"'
expect "ssh bash script"    skip 'ssh root@node "bash /root/tappaas/x.sh"'
expect "ssh script dry run" run  'ssh root@node "/root/tappaas/x.sh --dry-run"'

# An ssh that runs carries the variable; the remote command stays whole.
: > "${d}/ran"
TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; ssh -o X=1 root@node \"cd /tmp && echo 'a b'\"" >/dev/null
grep -q "root@node env TAPPAAS_SIMULATE=1 sh -c" "${d}/ran" && grep -q 'cd /tmp && echo' "${d}/ran" \
    && ok "ssh carries TAPPAAS_SIMULATE" || bad "ssh carry: $(cat "${d}/ran")"

# A script that sources nothing, started by something that is not gated, with
# BASH_ENV as exec.ts sets it.
printf '#!/usr/bin/env bash\nqm stop 100\n' > "${d}/plain.sh"
chmod +x "${d}/plain.sh"
: > "${d}/ran"
TAPPAAS_SIMULATE=1 BASH_ENV="${HERE}/simulate-gate.sh" CONFIG_DIR="${d}/config" env -u TAPPAAS_SIM_RULES "${d}/plain.sh" 2>/dev/null
[[ ! -s "${d}/ran" ]] && ok "BASH_ENV: a script that sources nothing is gated" || bad "BASH_ENV: $(cat "${d}/ran")"

# The file tools: under the config root skipped, elsewhere they run.
echo keep > "${d}/config/f"
echo out > "${d}/out"
TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1
rm -f '${d}/config/f'; mv '${d}/out' '${d}/config/f'; cp '${d}/out' '${d}/config/g'; sed -i s/keep/x/ '${d}/config/f'
echo y | tee '${d}/config/g' >/dev/null; touch '${d}/config/h'; echo z | tappaas_config_write '${d}/config/f'
cp '${d}/config/f' '${d}/copy'; touch '${d}/elsewhere'; tmp=\$(mktemp '${d}/config/f.XXXXXX'); echo x > \"\$tmp\"; mv \"\$tmp\" '${d}/config/f'" 2>/dev/null
[[ "$(cat "${d}/config/f")" == keep && ! -e "${d}/config/g" && ! -e "${d}/config/h" && -f "${d}/out" && "$(ls "${d}/config" | wc -l | tr -d ' ')" == 1 ]] \
    && ok "file tools under config/ skipped" || bad "file tools: $(ls "${d}/config")"
[[ "$(cat "${d}/copy" 2>/dev/null)" == keep && -e "${d}/elsewhere" ]] && ok "file tools elsewhere run, config/ still reads" || bad "file tools elsewhere"

# A script on ssh's stdin: judged too, and handed on when it only reads.
: > "${d}/ran"
err="$(TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; ssh root@node bash -s <<'X'
hostname
qm stop 100
X" 2>&1)"
[[ ! -s "${d}/ran" && "${err}" == *"[simulate] ssh root@node bash -s"* ]] && ok "ssh bash -s with a mutator: skipped" || bad "ssh bash -s: ${err}"
printf '#!/bin/sh\ncat >> "%s/ran"\n' "${d}" > "${d}/bin/ssh"
: > "${d}/ran"
TAPPAAS_SIMULATE=1 CONFIG_DIR="${d}/config" bash -c ". '${HERE}/common-install-routines.sh' >/dev/null 2>&1; ssh root@node bash -euo pipefail -s <<'X'
qm status 100
X"
grep -q 'qm status 100' "${d}/ran" && ok "ssh bash -s that reads: runs, script handed on" || bad "ssh bash -s read"

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
