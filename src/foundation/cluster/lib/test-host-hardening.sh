#!/usr/bin/env bash
#
# test-host-hardening.sh — cluster/setup-host-hardening.sh (#128) against a fake root.
#
# HOST_HARDENING_ROOT redirects every path it writes, HOST_HARDENING_DRY skips
# apt/auditctl/augenrules/systemctl (a fake dpkg records "installed"), and
# HOST_HARDENING_CPUINFO picks the CPU vendor. What it proves: the right
# microcode package per vendor, rules only for paths that exist, the syslog
# plugin switched on in place, and a second run that changes nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/../setup-host-hardening.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${S}" ]] || { echo "setup-host-hardening.sh not found — cannot run here."; exit 77; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hosthard.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT INT TERM

node() {   # node <vendor> — a fresh fake node; prints its root
    local r="${TMP}/$1.$RANDOM"; mkdir -p "${r}/etc/pve" "${r}/etc/ssh" "${r}/etc/network" "${r}/etc/audit/plugins.d"
    : > "${r}/etc/network/interfaces"
    printf 'active = no\ndirection = out\npath = /sbin/audisp-syslog\ntype = always\nargs = LOG_INFO\nformat = string\n' > "${r}/etc/audit/plugins.d/syslog.conf"
    printf 'processor\t: 0\nvendor_id\t: %s\n' "$1" > "${r}.cpuinfo"
    echo "${r}"
}
run() { HOST_HARDENING_ROOT="$1" HOST_HARDENING_DRY=1 HOST_HARDENING_CPUINFO="$1.cpuinfo" bash "${S}" "$2" 2>&1; }

r="$(node AuthenticAMD)"
ck "check on a fresh node fails" "1" "$(run "${r}" check >/dev/null; echo $?)"
out="$(run "${r}" apply)"; rc=$?
ck "apply succeeds" "0" "${rc}"
ck "AMD gets amd64-microcode" "yes" "$(grep -q 'installed amd64-microcode' <<<"${out}" && echo yes || echo no)"
ck "auditd is installed" "yes" "$([[ -e ${r}/var/lib/dpkg/fake-installed/auditd ]] && echo yes || echo no)"
rules="$(cat "${r}/etc/audit/rules.d/50-tappaas.rules")"
ck "rules cover /etc/pve, login sessions only" "2" "$(grep -c -- '-F dir=/etc/pve -F perm=wa -F auid!=unset -k tappaas-pve' <<<"${rules}")"
ck "both architectures" "b32,b64" "$(grep -oE 'arch=b[0-9]+' <<<"${rules}" | sort -u | cut -d= -f2 | paste -sd, -)"
ck "a path the node lacks is left out (/root/.ssh, interfaces.d)" "0" "$(grep -cE '/root/.ssh|interfaces.d' <<<"${rules}")"
ck "the interfaces file is watched" "2" "$(grep -c 'path=/etc/network/interfaces ' <<<"${rules}")"
ck "the syslog plugin is switched on in place" "active = yes" "$(grep '^active' "${r}/etc/audit/plugins.d/syslog.conf")"
ck "the rest of the plugin file is kept" "path = /sbin/audisp-syslog" "$(grep '^path' "${r}/etc/audit/plugins.d/syslog.conf")"
ck "check passes after apply" "0" "$(run "${r}" check >/dev/null; echo $?)"
again="$(run "${r}" apply)"
ck "a second apply changes nothing" "" "$(grep -E ': installed|written|plugin on' <<<"${again}")"

mkdir -p "${r}/root/.ssh"
out="$(run "${r}" apply)"
ck "a path that appears is added on the next apply" "yes" "$(grep -q 'rules written' <<<"${out}" && grep -q '/root/.ssh' "${r}/etc/audit/rules.d/50-tappaas.rules" && echo yes || echo no)"

r="$(node GenuineIntel)"; rm -f "${r}/etc/audit/plugins.d/syslog.conf"
out="$(run "${r}" apply)"
ck "Intel gets intel-microcode" "yes" "$(grep -q 'installed intel-microcode' <<<"${out}" && echo yes || echo no)"
ck "a missing plugin file is written, active" "active = yes" "$(grep '^active' "${r}/etc/audit/plugins.d/syslog.conf")"

ck "an unknown mode is a usage error" "2" "$(run "${r}" frobnicate >/dev/null; echo $?)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
