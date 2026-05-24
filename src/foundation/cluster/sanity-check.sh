#!/usr/bin/env bash
#
# TAPPaaS Sanity Check (sanity-check.sh)
#
# Run after the OPNsense firewall is up and this node has been moved onto the
# management network (i.e. after the "swap cables" step). It verifies the basic
# plumbing the rest of the foundation install depends on: the node is on the
# mgmt subnet, the firewall is its gateway and reachable, internal + external
# DNS resolve, and the internet is reachable. Read-only; makes no changes.
#
# Usage: sanity-check.sh [--fw-ip <ip>] [--mgmt-cidr <prefix>] [-h|--help]
# Defaults: --fw-ip 10.0.0.1   --mgmt-cidr 10.0.0.
#
# Exit codes: 0 all checks passed, 1 one or more failed, 2 bad usage.

set -uo pipefail   # not -e: we want to run every check and summarise

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[sanity]${CL} $*"; }
pass()  { echo -e "  ${GN}✓${CL} $*"; PASS=$((PASS+1)); }
fail()  { echo -e "  ${RD}✗${CL} $*"; FAIL=$((FAIL+1)); }
warn()  { echo -e "  ${YW}!${CL} $*"; WARN=$((WARN+1)); }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; }

FW_IP="10.0.0.1"
MGMT_CIDR="10.0.0."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw-ip)     FW_IP="${2:-}"; shift 2 ;;
    --mgmt-cidr) MGMT_CIDR="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

PASS=0 FAIL=0 WARN=0
info "${BOLD}TAPPaaS sanity checks${CL} (firewall ${BL}${FW_IP}${CL})"

# 1. This node has an address on the management subnet.
node_ip="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${MGMT_CIDR}" | head -1)"
if [[ -n "$node_ip" ]]; then pass "Node has a management IP: ${node_ip}"
else fail "Node has no ${MGMT_CIDR}x address — is it on the management network yet?"; fi

# 2. Default gateway is the firewall.
gw="$(ip -o -4 route show default 2>/dev/null | awk '{print $3}' | head -1)"
if [[ "$gw" == "$FW_IP" ]]; then pass "Default gateway is the firewall (${FW_IP})"
else fail "Default gateway is '${gw:-none}', expected ${FW_IP} (run config-network.sh --swap-cables?)"; fi

# 3. Firewall reachable (ping).
if ping -c1 -W2 "$FW_IP" >/dev/null 2>&1; then pass "Firewall ${FW_IP} responds to ping"
else fail "Firewall ${FW_IP} not reachable (ping)"; fi

# 4. Firewall web GUI listening (443 bootstrap, or 8443 once Caddy/cicd is up).
gui=""
for port in 443 8443; do
  if curl -ksS -o /dev/null --max-time 5 "https://${FW_IP}:${port}/" 2>/dev/null; then gui="$port"; break; fi
done
if [[ -n "$gui" ]]; then pass "Firewall web GUI answering on https://${FW_IP}:${gui}"
else warn "Firewall web GUI not answering on 443/8443 (may still be booting)"; fi

# 5. Internal DNS resolves the firewall name to the firewall.
int_ip="$(getent hosts firewall.mgmt.internal 2>/dev/null | awk '{print $1}' | head -1)"
if [[ "$int_ip" == "$FW_IP" ]]; then pass "Internal DNS: firewall.mgmt.internal → ${FW_IP}"
elif [[ -n "$int_ip" ]]; then warn "Internal DNS: firewall.mgmt.internal → ${int_ip} (expected ${FW_IP})"
else fail "Internal DNS cannot resolve firewall.mgmt.internal (resolver = ${FW_IP}?)"; fi

# 6. External DNS resolves a public name.
if getent hosts tappaas.org >/dev/null 2>&1 || getent hosts example.com >/dev/null 2>&1; then
  pass "External DNS resolves public names"
else fail "External DNS cannot resolve public names (forwarding/Unbound issue?)"; fi

# 7. Internet egress.
if curl -fsS -o /dev/null --max-time 8 https://1.1.1.1/ 2>/dev/null || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
  pass "Internet is reachable"
else fail "No internet egress (firewall WAN / routing?)"; fi

echo ""
info "Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${WARN} warnings${CL}"
[[ "$FAIL" -eq 0 ]] && { info "${GN}Sanity checks passed.${CL}"; exit 0; }
info "${RD}Some checks failed — resolve before continuing the foundation install.${CL}"
exit 1
