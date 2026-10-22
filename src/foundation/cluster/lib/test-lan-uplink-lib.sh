#!/usr/bin/env bash
# Unit tests for lan-uplink-lib.sh (#40): declaration, port names, findings.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lan-uplink-lib.sh
. "${HERE}/lan-uplink-lib.sh"
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf '  FAIL: %s\n    got:  %s\n    want: %s\n' "$1" "$2" "$3"; fi; }

port() {  # name mac speed [state] [aggregator] [chassis]
    jq -cn --arg n "$1" --arg m "$2" --argjson s "$3" --arg st "${4:-up}" --arg a "${5:-}" --arg c "${6:-}" \
        '{name: $n, mac: $m, state: $st, speed: $s, mtu: 1500, mii: (if $a == "" then "" else "up" end),
          aggregator: $a, lldp: (if $c == "" then null else {chassis: $c, name: $c, port: "1"} end)}'
}
TG0="$(port tg0 aa:00:00:00:00:01 10000 up 1 sw1)"
TG1="$(port tg1 aa:00:00:00:00:02 10000 up 1 sw2)"
GE0="$(port ge0 aa:00:00:00:00:03 1000 up "" sw2)"
GE1="$(port ge1 aa:00:00:00:00:04 1000)"

# live <members-json> <mode> <bond> [lrm] [active] [primary] [agg] [partner]
live() {
    jq -cn --argjson m "$1" --arg mode "$2" --arg bond "$3" --argjson lrm "${4:-true}" \
        --arg act "${5:-}" --arg pri "${6:-}" --arg agg "${7:-}" --arg par "${8:-}" \
        --argjson ports "[${TG0},${TG1},${GE0},${GE1}]" --argjson wan "[${GE1}]" \
        '{node: "tappaas2", ports: $ports,
          lan: {mtu: 1500, bond: $bond, mode: $mode, active: $act, primary: $pri,
                primaryMac: ([$m[] | select(.name == $pri) | .mac][0] // ""),
                aggregator: $agg, partnerMac: $par, bondMtu: (if $bond == "" then null else 1500 end), members: $m},
          wan: {members: $wan}, lrmActive: $lrm, corosync: {links: 1, disconnected: 0}, lldpd: "active"}'
}
findings() { jq -cn --argjson l "$1" --argjson d "${2:-null}" '{node: "tappaas2", live: $l, declared: $d}' | lu_findings; }
texts() { jq -r '[.[] | "\(.level): \(.text)"] | join(" | ")'; }
has() { [[ "$(findings "$1" "${2:-null}" | texts)" == *"$3"* ]] && echo yes || echo no; }

SINGLE="$(live "[${TG0}]" single "")"
check "single port, fencing armed: warned" "$(has "${SINGLE}" '' 'fencing is armed and lan has one port (tg0)')" yes
check "single port, no HA: not warned"     "$(has "$(live "[${TG0}]" single "" false)" '' 'fencing')" no
check "nothing declared: told it will be recorded" "$(has "${SINGLE}" '' 'no uplinks declared')" yes

DECL="$(lu_declaration <<<"${SINGLE}")"
check "capture: a single port by MAC"      "${DECL}" '{"lan":{"ports":["aa:00:00:00:00:01"],"mode":"single"},"wan":{"ports":["aa:00:00:00:00:04"]}}'
check "captured equals live: no drift"     "$(has "${SINGLE}" "${DECL}" 'drift')" no

AB="$(live "[${TG0},${GE0}]" active-backup lanbond true tg0 tg0)"
check "capture: active-backup keeps its primary" "$(lu_declaration <<<"${AB}" | jq -c .lan)" '{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:03"],"mode":"active-backup","primary":"aa:00:00:00:00:01"}'
check "healthy active-backup on two switches: nothing to say" "$(findings "${AB}" "$(lu_declaration <<<"${AB}")")" "[]"
check "running on the backup: warned" "$(has "$(live "[${TG0},${GE0}]" active-backup lanbond true ge0 tg0)" '' 'runs on ge0, not on its primary tg0')" yes
DOWN="$(port tg0 aa:00:00:00:00:01 -1 down 1 sw1)"
check "a leg down: warned" "$(has "$(live "[${DOWN},${GE0}]" active-backup lanbond true ge0 tg0)" '' 'tg0 is down')" yes

# A USB leg (#849): down says how to bring it back; a declared one the node does
# not have at all (pulled out) is named; with it present nothing is said.
USBDOWN="$(port usblan0 aa:00:00:00:00:09 -1 down 1 sw2 | jq -c '.usb = true')"
check "a USB leg down: says replug or ifup" "$(has "$(live "[${TG0},${USBDOWN}]" active-backup lanbond true tg0 tg0)" '' 'a USB NIC: replug it, or on the node: ifup lanbond')" yes
ABDECL='{"lan":{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:09"],"mode":"active-backup","primary":"aa:00:00:00:00:01"}}'
check "a declared USB leg the node lacks: named" "$(has "$(live "[${TG0}]" single "" true)" "${ABDECL}" 'declared lan port aa:00:00:00:00:09 is not on tappaas2')" yes
check "every declared port present: no such finding" "$(has "${AB}" "$(lu_declaration <<<"${AB}")" 'is not on tappaas2')" no

LACP_OK="$(live "[${TG0},${TG1}]" lacp lanbond true '' '' 1 02:11:22:33:44:55)"
check "healthy LACP across two switches"   "$(findings "${LACP_OK}" "$(lu_declaration <<<"${LACP_OK}")")" "[]"
check "LACP without a partner: no LAG"     "$(has "$(live "[${TG0},${TG1}]" lacp lanbond true '' '' 1 00:00:00:00:00:00)" '' 'no LACP partner')" yes
TG1B="$(port tg1 aa:00:00:00:00:02 10000 up 2 sw2)"
check "a leg outside the aggregator"       "$(has "$(live "[${TG0},${TG1B}]" lacp lanbond true '' '' 1 02:11:22:33:44:55)" '' 'tg1 is outside the active aggregator')" yes

# LACP port state (#40, seen on tappaas1 2026-10-16): 63 actor / 61 partner is a
# leg in the LAG with a switch asking for the slow rate; 199 is expired, 7 not in sync.
lstate() { jq -c --argjson a "$2" --argjson p "$3" '. + {actorState: $a, partnerState: $p}' <<<"$1"; }
SYNC_FAST="$(live "[$(lstate "${TG0}" 63 63),$(lstate "${TG1}" 63 63)]" lacp lanbond true '' '' 1 02:11:22:33:44:55)"
check "both legs in sync, fast partner: nothing to say" "$(findings "${SYNC_FAST}" "$(lu_declaration <<<"${SYNC_FAST}")")" "[]"
SLOW="$(live "[$(lstate "${TG0}" 63 61),$(lstate "${TG1}" 63 61)]" lacp lanbond true '' '' 1 02:11:22:33:44:55)"
check "a partner on the slow rate: warned once" "1" "$(findings "${SLOW}" | jq '[.[] | select(.text | test("slow LACP rate"))] | length')"
EXPIRED="$(live "[$(lstate "${TG0}" 63 63),$(lstate "${TG1}" 199 2)]" lacp lanbond true '' '' 1 02:11:22:33:44:55)"
check "a leg whose LACP expired: not carrying traffic" "$(has "${EXPIRED}" '' "tg1 is not carrying traffic in the LAG (LACP state 199, the LACP from the switch on it expired)")" yes
NOSYNC="$(live "[$(lstate "${TG0}" 63 63),$(lstate "${TG1}" 7 197)]" lacp lanbond true '' '' 1 02:11:22:33:44:55)"
check "a leg not in sync: not carrying traffic" "$(has "${NOSYNC}" '' 'tg1 is not carrying traffic in the LAG (LACP state 7)')" yes
check "…and the healthy leg is not named" "$(has "${NOSYNC}" '' 'tg0 is not carrying')" no

TG1S="$(port tg1 aa:00:00:00:00:02 10000 up 1 sw1)"
check "both legs on one switch"            "$(has "$(live "[${TG0},${TG1S}]" lacp lanbond true '' '' 1 02:11:22:33:44:55)" '' 'same switch (sw1)')" yes
TG1N="$(port tg1 aa:00:00:00:00:02 10000 up 1)"
check "no LLDP from a leg: unknown, not a warning" "$(findings "$(live "[${TG0},${TG1N}]" lacp lanbond true '' '' 1 02:11:22:33:44:55)" | jq -r '[.[] | select(.text | test("LLDP")) | .level] | join(",")')" "info"

check "declared bond, live single: drift" "$(has "${SINGLE}" '{"lan":{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:02"],"mode":"lacp"}}' 'drift: declared lacp')" yes
check "declared MAC gone: a replaced NIC" "$(has "${SINGLE}" '{"lan":{"ports":["aa:00:00:00:00:99"]}}' 'not on tappaas2')" yes
check "declared primary differs: drift"   "$(has "${AB}" '{"lan":{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:03"],"mode":"active-backup","primary":"aa:00:00:00:00:03"}}' 'drift')" yes
check "declared MACs match in any case"   "$(has "${AB}" '{"lan":{"ports":["AA:00:00:00:00:03","aa:00:00:00:00:01"],"mode":"active-backup"}}' 'drift')" no

check "wan declared as no port, live still on ge1: drift" "$(has "${AB}" '{"lan":{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:03"],"mode":"active-backup"},"wan":{"ports":[]}}' 'drift: declared wan on no port, live wan on aa:00:00:00:00:04')" yes
check "wan as declared: no wan drift"    "$(has "${AB}" '{"wan":{"ports":["AA:00:00:00:00:04"]}}' 'drift: declared wan')" no
check "wan not declared: not compared"   "$(has "${AB}" '{"lan":{"ports":["aa:00:00:00:00:01","aa:00:00:00:00:03"],"mode":"active-backup"}}' 'wan')" no

check "pending interfaces.new: warned" "$(has "$(jq -c '.pendingNew = true' <<<"${AB}")" '' 'interfaces.new holds pending network changes')" yes
check "no interfaces.new: quiet"      "$(has "${AB}" '' 'interfaces.new')" no

check "names resolve to name and MAC"     "$(lu_resolve_ports "${AB}" tg1,ge0 | paste -sd' ' -)" "tg1 aa:00:00:00:00:02 ge0 aa:00:00:00:00:03"
check "a MAC resolves to its port"        "$(lu_resolve_ports "${AB}" AA:00:00:00:00:04)" "ge1 aa:00:00:00:00:04"
lu_resolve_ports "${AB}" eth9 >/dev/null 2>&1 && r=resolved || r=refused
check "an unknown port is refused"        "${r}" refused

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
