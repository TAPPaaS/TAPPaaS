#!/usr/bin/env bash
#
# test-guest-hook.sh — cluster/setup-guest-hook.sh (#127) against a fake root,
# and the hookscript it installs against a local listener.
#
# What it proves: the hook is attached to every guest on the node except the
# firewall, a guest's own hookscript is kept, a second apply changes nothing, a
# site with no firewall VM gets a no-op; and the hook itself starts at once when
# the firewall answers, waits while it does not, and never fails a start.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/../setup-guest-hook.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/guesthook.XXXXXX")"; LPID=""
trap '[[ -n "${LPID}" ]] && kill "${LPID}" 2>/dev/null; rm -rf "${T}"' EXIT INT TERM

r="${T}/root"; q="${r}/etc/pve/nodes/n1/qemu-server"; l="${r}/etc/pve/nodes/n1/lxc"
mkdir -p "${q}" "${l}"
printf 'name: network\nonboot: 1\n' > "${q}/110.conf"
printf 'name: app\nonboot: 1\n[snap1]\nname: app\n' > "${q}/130.conf"
printf 'name: own\nhookscript: local:snippets/theirs.pl\n' > "${q}/200.conf"
printf 'hostname: ct\n' > "${l}/925.conf"
run() { HOST_HOOK_ROOT="${r}" HOST_HOOK_DRY=1 HOST_HOOK_NODE=n1 HOST_HOOK_GW=10.9.9.1 bash "${S}" "$@" 2>&1; }

ck "check before apply fails" "1" "$(run check >/dev/null; echo $?)"
out="$(run apply 110)"; rc=$?
ck "apply succeeds" "0" "${rc}"
ck "the hook is installed, executable" "yes" "$([[ -x ${r}/var/lib/vz/snippets/tappaas-guest-hook.sh ]] && echo yes || echo no)"
ck "settings name the firewall and the gateway" "FW_VMID=110 FW_ADDR=10.9.9.1" \
   "$(grep -E '^FW_(VMID|ADDR)=' "${r}/etc/tappaas/firewall-wait.env" | tr '\n' ' ' | sed 's/ $//')"
ck "attached to the VM and the container, in that order" "qm set 130 --hookscript local:snippets/tappaas-guest-hook.sh|pct set 925 --hookscript local:snippets/tappaas-guest-hook.sh" \
   "$(paste -sd'|' "${r}/hook-calls.log")"
ck "the firewall itself carries no hook" "0" "$(grep -c hookscript "${q}/110.conf")"
ck "a guest's own hookscript is kept" "local:snippets/theirs.pl" "$(sed -n 's/^hookscript: //p' "${q}/200.conf")"
ck "…and reported" "yes" "$(grep -q 'own hookscript.* 200' <<<"${out}" && echo yes || echo no)"
ck "check passes after apply" "0" "$(run check >/dev/null; echo $?)"
: > "${r}/hook-calls.log"
again="$(run apply 110)"
ck "a second apply changes nothing" "" "$(grep -E 'installed|written|attached' <<<"${again}"; cat "${r}/hook-calls.log")"
printf 'name: new\n' > "${q}/131.conf"
out="$(run apply 110)"
ck "a guest that appears is attached on the next apply" "yes" "$(grep -q 'attached to 131' <<<"${out}" && echo yes || echo no)"
ck "no firewall VM ('-'): settings emptied, check says so" "yes" \
   "$(run apply - >/dev/null; [[ ! -s ${r}/etc/tappaas/firewall-wait.env || -z $(grep FW_VMID "${r}/etc/tappaas/firewall-wait.env") ]] && run check | grep -c 'no firewall VM' >/dev/null && echo yes || echo no)"
ck "a bad firewall id is a usage error" "2" "$(run apply abc >/dev/null; echo $?)"

# ── the hookscript itself ──
H="${T}/hook.sh"; E="${T}/fw.env"; LOG="${T}/logger.log"
sed "s#/etc/tappaas/firewall-wait.env#${E}#g" "${r}/var/lib/vz/snippets/tappaas-guest-hook.sh" > "${H}"
mkdir -p "${T}/bin"; printf '#!/bin/sh\necho "$*" >> "%s"\n' "${LOG}" > "${T}/bin/logger"; chmod +x "${T}/bin/logger"
hook() { PATH="${T}/bin:${PATH}" bash "${H}" "$@"; }
PORT=$(( 20000 + RANDOM % 20000 ))
if command -v python3 >/dev/null && command -v timeout >/dev/null; then
    python3 -c "import socket,sys;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',${PORT}));s.listen(8)
while True: s.accept()[0].close()" & LPID=$!
    sleep 0.5
    printf 'FW_VMID=110\nFW_ADDR=127.0.0.1\nFW_PORT=%s\nFW_WAIT_MAX=10\n' "${PORT}" > "${E}"
    s0=$SECONDS; hook 130 pre-start; rc=$?
    ck "firewall answers: starts at once, rc 0" "0 0" "${rc} $(( SECONDS - s0 ))"
    ck "…and says nothing" "" "$(cat "${LOG}" 2>/dev/null)"
    kill "${LPID}" 2>/dev/null; wait "${LPID}" 2>/dev/null; LPID=""
    printf 'FW_VMID=110\nFW_ADDR=127.0.0.1\nFW_PORT=%s\nFW_WAIT_MAX=5\n' "${PORT}" > "${E}"
    s0=$SECONDS; hook 130 pre-start; rc=$?
    ck "firewall silent: waits its maximum, then starts (rc 0)" "0" "${rc}"
    ck "…having waited" "yes" "$( (( SECONDS - s0 >= 5 )) && echo yes || echo no)"
    ck "…and logged the wait and the give-up" "2" "$(grep -cE 'waiting up to 5s|did not answer in 5s' "${LOG}")"
else
    echo "  (python3 or timeout(1) not found — the hook's wait is not exercised here)"
fi
: > "${LOG}"
ck "the firewall's own start never waits" "0 0" "$(s0=$SECONDS; hook 110 pre-start; echo "$? $(( SECONDS - s0 ))")"
ck "other phases are ignored" "0 0" "$(s0=$SECONDS; hook 130 post-start; echo "$? $(( SECONDS - s0 ))")"
rm -f "${E}"
ck "no settings file: no wait" "0 0" "$(s0=$SECONDS; hook 130 pre-start; echo "$? $(( SECONDS - s0 ))")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
