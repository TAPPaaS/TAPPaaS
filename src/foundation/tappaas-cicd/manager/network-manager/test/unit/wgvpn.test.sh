#!/usr/bin/env bash
#
# wgvpn.test.sh — the admin VPN's client config (#856), offline.
#
# Sources wgvpn/wgvpn-lib.sh with the OPNsense API replaced by fixtures
# (test/fixtures/wgvpn/, captured from hrossen) and zones.json by the test
# fixture, and checks what `wgvpn config` and `wgvpn list` print: the site's
# DNS, mgmt, the DMZ gateway /32 and its IPv6 /128 — or a note when the site
# has no IPv6 — and which peers still hold a config from before #856.
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NM="$(cd "${HERE}/../.." && pwd)"
FX="${HERE}/../fixtures/wgvpn"
PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

# shellcheck source=../../wgvpn/wgvpn-lib.sh
. "${NM}/wgvpn/wgvpn-lib.sh"

IFACES="${FX}/interfacesInfo.json"
_ow_api() {
    local path="${!#}"
    case "${path}" in
        */interfaces/overview/interfacesInfo) cat "${IFACES}" ;;
        */wireguard/server/searchServer)      cat "${FX}/searchServer.json" ;;
        */wireguard/server/getServer/*)       cat "${FX}/getServer.json" ;;
        */wireguard/client/searchClient)      cat "${FX}/searchClient.json" ;;
        */firewall/filter/searchRule)         cat "${FX}/searchRule.json" ;;
        *) echo '{}' ;;
    esac
}

export TAPPAAS_CONFIG_DIR="${TMP}/config"
mkdir -p "${TAPPAAS_CONFIG_DIR}"
ZONES="${TAPPAAS_CONFIG_DIR}/zones.json"
# The test fixture's dmz has no ipv6Subnet; hrossen's has 97.
jq '.dmz.ipv6Subnet = 97' "${HERE}/../fixtures/zones.json" > "${ZONES}"

line() { grep -E "^$1 *=" <<<"$2" | sed -E 's/^[^=]*= *//'; }

echo "== wgvpn: the client config (#856) =="

# ── gateway arithmetic ──
[[ "$(av_first_host 10.0.0.0/24)" == 10.0.0.1 ]] && ok "first host of 10.0.0.0/24 is 10.0.0.1" || bad "first host of 10.0.0.0/24"
[[ "$(av_first_host 10.6.0.17/24)" == 10.6.0.1 ]] && ok "first host of an unaligned 10.6.0.17/24 is 10.6.0.1" || bad "unaligned first host"
[[ "$(av_first_host 172.16.0.0/12)" == 172.16.0.1 ]] && ok "first host of 172.16.0.0/12 is 172.16.0.1" || bad "/12 first host"
av_first_host 10.6.0.0 >/dev/null 2>&1 && bad "a network without a prefix length was accepted" || ok "a network without a prefix length is refused"

# ── a site with IPv6 (hrossen) ──
cfg="$(av_client_config 10.255.1.2/32 80.248.138.190:51821 2>"${TMP}/err")"
[[ "$(line DNS "${cfg}")" == 10.0.0.1 ]] && ok "DNS = the mgmt gateway (10.0.0.1)" || bad "DNS line: '$(line DNS "${cfg}")'"
want="10.0.0.0/24, 10.6.0.1/32, 2a13:e747:a210:8261:98:34ff:fe69:901a/128"
[[ "$(line AllowedIPs "${cfg}")" == "${want}" ]] && ok "AllowedIPs = mgmt, the DMZ gateway /32 and its global IPv6 /128" \
    || bad "AllowedIPs: '$(line AllowedIPs "${cfg}")' (want '${want}')"
[[ "$(line Address "${cfg}")" == 10.255.1.2/32 && "$(line Endpoint "${cfg}")" == 80.248.138.190:51821 ]] \
    && ok "the peer's own Address and Endpoint are kept" || bad "Address/Endpoint changed"
[[ "$(line PublicKey "${cfg}")" == "Ov1AdZIdxOnGZa3FyZ4HpUAqfb6lP+A1qBd2nzWcMQ0=" ]] && ok "PublicKey is the admin server's" || bad "PublicKey"
grep -q '^# tappaas-admin client config v2' <<<"${cfg}" && ok "the config says its version (v2)" || bad "no version line"
grep -q 'no IPv6 route' <<<"${cfg}" && bad "a note about IPv6 on a site that has it" || ok "no IPv6 note on a site with IPv6"
[[ ! -s "${TMP}/err" ]] && ok "nothing on stderr" || bad "stderr: $(cat "${TMP}/err")"

# ── the dmz zone has no ipv6Subnet ──
jq 'del(.dmz.ipv6Subnet)' "${HERE}/../fixtures/zones.json" > "${ZONES}"
cfg="$(av_client_config 10.255.1.2/32 x:51821 2>/dev/null)"
[[ "$(line AllowedIPs "${cfg}")" == "10.0.0.0/24, 10.6.0.1/32" ]] && ok "no ipv6Subnet: AllowedIPs = mgmt and the DMZ gateway /32" \
    || bad "no ipv6Subnet: AllowedIPs '$(line AllowedIPs "${cfg}")'"
grep -q '^# no IPv6 route: the dmz zone has no ipv6Subnet' <<<"${cfg}" && ok "…with a note saying why" || bad "no-ipv6Subnet note missing"

# ── ipv6Subnet set, but the firewall's dmz interface has no global IPv6 ──
jq '.dmz.ipv6Subnet = 97' "${HERE}/../fixtures/zones.json" > "${ZONES}"
IFACES="${TMP}/ifaces-v4.json"
jq '.rows |= map(.ipv6 |= map(select(.ipaddr | startswith("fe80"))))' "${FX}/interfacesInfo.json" > "${IFACES}"
cfg="$(av_client_config 10.255.1.2/32 x:51821 2>/dev/null)"
[[ "$(line AllowedIPs "${cfg}")" == "10.0.0.0/24, 10.6.0.1/32" ]] && ok "no global IPv6 on dmz: no /128 (link-local is not used)" \
    || bad "link-local-only: AllowedIPs '$(line AllowedIPs "${cfg}")'"
grep -q "^# no IPv6 route: the firewall's dmz interface (10.6.0.1) has no global IPv6 address" <<<"${cfg}" \
    && ok "…with a note saying why" || bad "no-global-v6 note missing"
IFACES="${FX}/interfacesInfo.json"

# ── no zones.json: mgmt as before, a warning, no DMZ route ──
rm -f "${ZONES}"
cfg="$(av_client_config 10.255.1.2/32 x:51821 2>"${TMP}/err")"
[[ "$(line AllowedIPs "${cfg}")" == "${AV_MGMT_SUBNET}" && "$(line DNS "${cfg}")" == 10.0.0.1 ]] \
    && ok "no zones.json: mgmt only, DNS from the mgmt default" || bad "no zones.json: '$(line AllowedIPs "${cfg}")'"
grep -q 'no dmz zone' "${TMP}/err" && ok "…and a warning that the published names have no route" || bad "no warning without zones.json"
jq '.dmz.ipv6Subnet = 97' "${HERE}/../fixtures/zones.json" > "${ZONES}"

# ── which peers hold a config from before #856 ──
out="$(av_list 2>/dev/null)"
grep -qE '^  - lars-mac  10\.255\.1\.2/32  config v1: no DNS, mgmt only — re-issue \(network-manager wgvpn config lars-mac\) and re-import$' <<<"${out}" \
    && ok "list: a peer with no record is v1, with the command that re-issues it" || bad "list (before): $(grep lars-mac <<<"${out}")"
grep -q satellite1 <<<"${out}" && bad "list shows a peer outside the admin overlay" || ok "list keeps to the admin overlay's peers"

cfg="$(av_config_cmd lars-mac "" "" 2>/dev/null)"
[[ "$(line Address "${cfg}")" == 10.255.1.2/32 ]] && ok "config <name>: the peer's address is looked up" || bad "config <name>: Address '$(line Address "${cfg}")'"
[[ "$(line Endpoint "${cfg}")" == "<satellite-or-cluster-public-ip>:51821" ]] && ok "config <name>: Endpoint found as add-peer finds it" \
    || bad "config <name>: Endpoint '$(line Endpoint "${cfg}")'"
[[ "$(jq -r '."lars-mac".config' "$(av_issued_file)" 2>/dev/null)" == 2 ]] && ok "config <name> records v2 as issued to the peer" || bad "nothing recorded in $(av_issued_file)"
out="$(av_list 2>/dev/null)"
grep -qE "^  - lars-mac  10\.255\.1\.2/32  config v2 issued [0-9]{4}-[0-9]{2}-[0-9]{2}$" <<<"${out}" \
    && ok "list: the re-issued peer is v2" || bad "list (after): $(grep lars-mac <<<"${out}")"
grep -q 'lars-phone  10.255.1.3/32  config v1' <<<"${out}" && ok "list: the other peer is still v1" || bad "list: lars-phone"

av_config_cmd 10.255.1.3/32 h:1 >/dev/null 2>&1
[[ "$(jq -r '."lars-phone".ip' "$(av_issued_file)")" == 10.255.1.3/32 ]] && ok "config <ip/32> records the peer that has the address" || bad "config <ip/32> not recorded"
av_config_cmd nosuch >/dev/null 2>&1 && bad "config of an unknown name succeeded" || ok "config of an unknown name is refused"
av_forget_issued lars-phone
[[ "$(jq -r 'has("lars-phone")' "$(av_issued_file)")" == false ]] && ok "remove-peer forgets the record" || bad "record kept after forget"

# The console's setup view reads the peer names off `list` (ui/src/setup.ts):
# the version after the address must not change what it reads.
[[ "$(sed -n 's/^  - \([^ ]*\) .*/\1/p' <<<"${out}" | tr '\n' ,)" == "lars-mac,lars-phone," ]] \
    && ok "list: the peer name is still the first word of its row" || bad "list row format"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
