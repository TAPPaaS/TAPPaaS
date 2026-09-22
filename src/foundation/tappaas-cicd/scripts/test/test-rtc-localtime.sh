#!/usr/bin/env bash
#
# test-rtc-localtime.sh — the emulated RTC is read the way the guest OS expects
# (#699).
#
# Proxmox's `localtime` decides how a guest interprets the emulated clock.
# Windows expects it in local time; Linux and FreeBSD keep it in UTC (NixOS:
# boot.hardwareClockInLocalTime defaults to false). The wrong value does not
# fail a boot — it starts the guest a whole TZ offset AHEAD of real time until
# NTP walks it back. On hrossen that was two hours, and it is how `logging`
# failed its pre-update health check while being perfectly healthy: Loki was
# still settling after the clock jumped backwards under it.
#
# Until #699 the value was a literal in four separate `qm create` calls. #166
# fixed one of them. A guest's clock therefore depended on which creation path
# it happened to take, and three guests on hrossen (logging, openwebui,
# unifi-os) still carried localtime: 1 months later.
#
# Tabletop: reads the shipped scripts, creates nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE="$(cd "${HERE}/../../../cluster" 2>/dev/null && pwd)/Create-TAPPaaS-VM.sh"
UPDATE="$(cd "${HERE}/../../../cluster/services/vm" 2>/dev/null && pwd)/update-service.sh"
[[ -f "${CREATE}" && -f "${UPDATE}" ]] || {
    echo "cluster scripts not found beside this suite — cannot run here."; exit 77; }

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "── every creation path derives the flag, none hardcodes it ──"
# The bug was not "the value is wrong" but "the value is written four times".
_literals="$(grep -c -E 'qm create .*--?localtime (0|1)\b' "${CREATE}" 2>/dev/null || true)"
if [[ "${_literals}" -eq 0 ]]; then
    ok "no qm create passes a hardcoded localtime"
else
    bad "${_literals} qm create call(s) still pass a literal localtime"
    grep -n -E 'qm create .*--?localtime (0|1)\b' "${CREATE}" | sed 's/^/      /'
fi

_derived="$(grep -c -E 'qm create .*--?localtime \$\{?RTC_LOCALTIME' "${CREATE}" 2>/dev/null || true)"
if [[ "${_derived}" -ge 4 ]]; then
    ok "all ${_derived} creation paths use the derived value"
else
    bad "only ${_derived} creation path(s) use RTC_LOCALTIME (expected every one)"
fi

echo "── the rule itself: Windows local, everything else UTC ──"
# Evaluate the shipped case statement rather than restating it here, so this
# test cannot drift away from the code it guards.
_rule="$(sed -n '/^case "\$VM_OSTYPE" in/,/^esac/p' "${CREATE}")"
if [[ -n "${_rule}" ]]; then
    ok "the derivation is a single case on ostype"
    for _os in win10 win11 wvista wxp w2k8; do
        VM_OSTYPE="${_os}"; RTC_LOCALTIME=""
        eval "${_rule}"
        [[ "${RTC_LOCALTIME}" == "1" ]] && ok "${_os} → localtime 1" || bad "${_os} → '${RTC_LOCALTIME}' (expected 1)"
    done
    for _os in l26 l24 other solaris; do
        VM_OSTYPE="${_os}"; RTC_LOCALTIME=""
        eval "${_rule}"
        [[ "${RTC_LOCALTIME}" == "0" ]] && ok "${_os} → localtime 0" || bad "${_os} → '${RTC_LOCALTIME}' (expected 0)"
    done
else
    bad "no ostype case found in ${CREATE##*/} — the rule is not expressed once"
fi

echo "── existing guests are repaired, not just new ones ──"
# The three on hrossen were created months before the fix; a creation-time-only
# change would leave them booting skewed forever.
if grep -q 'qm set .*--localtime' "${UPDATE}"; then
    ok "cluster:vm update-service corrects a guest's localtime"
else
    bad "update-service never sets localtime — existing guests stay skewed"
fi
if grep -q 'w\*) _rtc_want=1' "${UPDATE}"; then
    ok "and it keeps Windows guests on local time"
else
    bad "the repair does not special-case Windows — it would break their clocks"
fi
if grep -qE '_rtc_want="\$\{_rtc_actual\}"' "${UPDATE}"; then
    ok "an unreadable ostype changes nothing"
else
    bad "the repair has no guard for an unreadable ostype"
fi
if grep -q 'CHECK_MODE.*!= *"1"' "${UPDATE}"; then
    ok "--check stays read-only"
else
    bad "the repair would write during a --check run"
fi

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
