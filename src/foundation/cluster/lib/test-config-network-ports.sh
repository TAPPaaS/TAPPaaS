#!/usr/bin/env bash
#
# test-config-network-ports.sh — the first node's LAN default (#915): the first
# port other than the WAN that has a link, else the first other port.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../config-network.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cnports.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
awk '/^other_port\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${SRC}" > "${TMP}/fn.sh"
ck "other_port is in config-network.sh" "yes" "$(grep -q 'other_port()' "${TMP}/fn.sh" && echo yes || echo no)"
# shellcheck source=/dev/null
. "${TMP}/fn.sh"

link() { mkdir -p "${TMP}/net/$1"; echo "$2" > "${TMP}/net/$1/carrier"; }
export SYS_NET="${TMP}/net"
PORTS=(nic0 nic1 nic2 nic3 nic4 nic5 nic6 nic7 nic8)
for p in "${PORTS[@]}"; do link "$p" 0; done
link nic4 1   # the WAN: the install ran on it
ck "no other port with a link: the first other port" "nic0" "$(other_port nic4)"
link nic6 1
ck "a cabled port wins over the ones before it" "nic6" "$(other_port nic4)"
link nic2 1
ck "…the first cabled one" "nic2" "$(other_port nic4)"
PORTS=(nic4)
ck "one port only: none" "" "$(other_port nic4 || true)"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
