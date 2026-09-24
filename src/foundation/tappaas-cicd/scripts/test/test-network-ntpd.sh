#!/usr/bin/env bash
#
# test-network-ntpd.sh — the network update converges the firewall's ntpd, and
# restarts it after reconfiguring OPNsense (#716).
#
# The network update is what knocks the firewall's ntpd over: while it
# reconfigures OPNsense, NTP replies are held for seconds, the delayed samples
# poison ntpd's clock filter, and it serves its own clock in orphan mode
# (stratum 12) for up to an hour. Guests accept that answer and never move on.
# The fix is two settings (orphan off, iburst) and a restart at the end of the
# update. The PHP runs on the firewall (exercised there against a stubbed
# config on 2026-09-24); this pins the wiring and the settings.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="$(cd "${HERE}/../../../network" && pwd)"
UPD="${NET}/update.sh"
PHP="${NET}/scripts/ntpd-converge.php"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
[[ -f "${UPD}" && -f "${PHP}" ]] || { echo "network update.sh / ntpd-converge.php not found — cannot run here."; exit 77; }

echo "── the converge script ──"
ck "orphan mode is turned off (orphan = 16)" "yes" \
   "$(grep -qE "\['orphan'\] = '16'" "${PHP}" && echo yes || echo no)"
ck "every upstream gets iburst" "yes" \
   "$(grep -qE "\['iburst'\] = \\\$want" "${PHP}" && grep -q "timeservers" "${PHP}" && echo yes || echo no)"
ck "config.xml is written only when something changed" "yes" \
   "$(grep -qE 'if \(\$changed\)' "${PHP}" && grep -q 'write_config' "${PHP}" && echo yes || echo no)"
if command -v php >/dev/null 2>&1; then
    ck "it is valid PHP" "0" "$(php -l "${PHP}" >/dev/null 2>&1; echo $?)"
fi

echo "── the network update ──"
ck "update.sh pipes the converge script to the firewall" "yes" \
   "$(grep -q 'scripts/ntpd-converge.php' "${UPD}" && grep -q "php /dev/stdin' < \"\${_ntp_php}\"" "${UPD}" && echo yes || echo no)"
ck "…and restarts ntpd, which re-renders ntpd.conf" "yes" \
   "$(grep -q 'pluginctl -s ntpd restart' "${UPD}" && echo yes || echo no)"
# The restart must come after everything that reconfigures OPNsense, or it
# restarts ntpd into the stall it is meant to clear.
order="$(awk '/zone-manager/ && !z {z=NR} /configctl filter reload/ && !f {f=NR} /pluginctl -s ntpd restart/ && !r {r=NR} /Firewall update completed/ {c=NR} END {print (z && f && r && z<r && f<r && r<c) ? "after" : "before"}' "${UPD}")"
ck "the restart runs after the zone apply and the filter reload" "after" "${order}"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
