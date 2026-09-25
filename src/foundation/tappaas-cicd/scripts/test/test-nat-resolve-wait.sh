#!/usr/bin/env bash
#
# test-nat-resolve-wait.sh — network:nat waits for a new guest's DNS name.
#
# network:nat can run right after cluster:vm creates a guest, before its first
# DHCP lease registers <vmname>.<zone0>.internal. coturn's install on hrossen
# failed there ("Cannot resolve internal target") on a name that resolved seconds
# later, and left its VM behind. nat_resolve_target now waits, bounded.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC="$(readlink -f "${HERE}/../../../network/services/nat/nat-common.sh")"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${NC}" ]] || { echo "nat-common.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/natwait.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# resolve <lookups before the name appears> [NAT_DNS_WAIT] — prints "<ip or FAIL>|<lookups>|<slept s>"
resolve() {
    ANSWER_AFTER="$1" NAT_DNS_WAIT="${2:-60}" T="${TMP}" bash -c '
        : > "${T}/digs"; : > "${T}/sleeps"
        get_config_value() { case "$1" in vmname) echo coturn ;; zone0) echo dmz ;; *) echo "${2:-}" ;; esac; }
        dig() { echo x >> "${T}/digs"; local n; n=$(wc -l < "${T}/digs")
                (( n > ANSWER_AFTER )) && echo "10.6.0.170"; return 0; }
        sleep() { echo "$1" >> "${T}/sleeps"; }
        . "'"${NC}"'"
        ip=$(nat_resolve_target coturn) || ip=FAIL
        echo "${ip}|$(wc -l < "${T}/digs" | tr -d " ")|$(awk "{s+=\$1} END {print s+0}" "${T}/sleeps")"
    '
}

ck "a name that resolves at once: no wait"            "10.6.0.170|1|0"  "$(resolve 0)"
ck "a name that appears after two lookups: waits 10 s" "10.6.0.170|3|10" "$(resolve 2)"
ck "a name that never appears: gives up at the limit"  "FAIL|13|60"      "$(resolve 99)"
ck "NAT_DNS_WAIT=0: one lookup, no wait"               "FAIL|1|0"        "$(resolve 99 0)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
