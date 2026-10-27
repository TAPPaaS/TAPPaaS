#!/usr/bin/env bash
#
# install-access.sh — reach the console right after the bootstrap, to continue the
# install from the web (ADR-037 D3).
#
# The console runs on the mothership from the moment install.sh ends, unlocked by
# its setup token from mgmt and the admin VPN only, until identity is installed
# and the console module puts it behind the Authentik gate at console.<domain>.
# The operator who ran the bootstrap sits on neither, so `open` gives two ways in:
#
#   1. The first admin-VPN peer: a key pair made here and a ready wg-quick config
#      in config/admin-vpn/install-peer.conf (0600) — works at home and on a
#      hosted server alike. The private key is made on the mothership, unlike a
#      peer enrolled later with its own key: the trade for a config that works as
#      handed over. Remove it with `network-manager wgvpn remove-peer install`.
#   2. On a PRIVATE WAN subnet only (the install LAN at home, never the internet):
#      a port-forward of the firewall's WAN address, port 9097, to the console,
#      from that subnet alone, and the subnet added to what the console accepts
#      with the setup token (config/console-setup-allow).
#
# `close` removes the forward and the extra allow: the console module runs it once
# identity is installed (the setup token stops working then anyway).
#
# Usage: install-access.sh open | close | status
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
FW_HOST="${INSTALL_ACCESS_FIREWALL:-root@firewall.mgmt.internal}"
FW_KEY="${HOME}/.ssh/tappaas-fw"
CONSOLE_PORT=9097
NAT_DESC="TAPPaaS: console (install LAN, until identity)"
ALLOW_FILE="${CONFIG_DIR}/console-setup-allow"
PEER_NAME="install"
PEER_CONF="${CONFIG_DIR}/admin-vpn/install-peer.conf"

# The firewall's WAN address and prefix length: the interface of its default
# route ("192.168.14.94 20"). Empty when the firewall does not answer.
wan_of_firewall() {
    local out
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${FW_KEY}" "${FW_HOST}" 'sh -s' 2>/dev/null <<'EOF'
ifc=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
[ -n "$ifc" ] && ifconfig "$ifc" | awk '/inet / {print $2, $4; exit}'
EOF
)" || return 0
    local ip mask bits=0 n
    read -r ip mask <<<"${out}"
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "${mask}" =~ ^0x[0-9a-fA-F]{8}$ ]] || return 0
    n=$((mask))
    while (( n & 0x80000000 )); do bits=$((bits + 1)); n=$(( (n << 1) & 0xffffffff )); done
    echo "${ip} ${bits}"
}

# The network of <ip> <bits>, as a CIDR. Pure.
network_of() {
    local ip="$1" bits="$2" a b c d n m
    IFS=. read -r a b c d <<<"${ip}"
    n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    m=$(( bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff ))
    n=$(( n & m ))
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))/${bits}"
}

# True for an RFC 1918 network — an install LAN, never the internet. Pure.
is_private() {
    local a b
    IFS=. read -r a b _ <<<"${1%/*}"
    (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}

cicd_mgmt_ip() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

open_vpn_peer() {
    local wan_ip="$1"
    if [[ -s "${PEER_CONF}" ]]; then
        info "  ${GN}✓${CL} admin VPN: the install peer's config is ${PEER_CONF}"
        return 0
    fi
    if network-manager wgvpn list 2>/dev/null | grep -qE "^  - ${PEER_NAME} "; then
        warn "  admin VPN: a peer '${PEER_NAME}' exists but its config is gone — re-issue it with: network-manager wgvpn remove-peer ${PEER_NAME}, then rerun this"
        return 0
    fi
    local keys priv pub conf
    keys="$(nix-shell -p wireguard-tools --run 'p=$(wg genkey); printf "%s %s" "$p" "$(printf %s "$p" | wg pubkey)"' 2>/dev/null)" \
        || { warn "  admin VPN: could not make a key pair (nix-shell wireguard-tools) — enrol a device by hand: network-manager wgvpn add-peer"; return 0; }
    read -r priv pub <<<"${keys}"
    conf="$(network-manager wgvpn add-peer --name "${PEER_NAME}" --pubkey "${pub}" ${wan_ip:+--endpoint "${wan_ip}:51821"} 2>/dev/null)" \
        || { warn "  admin VPN: could not add the install peer — network-manager wgvpn add-peer --name ${PEER_NAME} --pubkey <key>"; return 0; }
    mkdir -p "$(dirname "${PEER_CONF}")"
    ( umask 077; sed "s|<PASTE-YOUR-PRIVATE-KEY>|${priv}|" <<<"${conf}" > "${PEER_CONF}" )
    info "  ${GN}✓${CL} admin VPN: an install peer, its config in ${PEER_CONF} (it holds a private key)"
}

open_lan() {
    local wan_ip="$1" bits="$2" net cicd
    net="$(network_of "${wan_ip}" "${bits}")"
    if ! is_private "${net}"; then
        info "  the WAN (${net}) is public: no install-LAN access — use the admin VPN"
        return 0
    fi
    cicd="$(cicd_mgmt_ip)"
    [[ -n "${cicd}" ]] || { warn "  install LAN: the mothership has no mgmt address — skipped"; return 0; }
    if ! nat-manager add-rule --no-ssl-verify --description "${NAT_DESC}" --external-port "${CONSOLE_PORT}" \
            --target "${cicd}" --internal-port "${CONSOLE_PORT}" --protocol TCP --interface wan \
            --source "${net}" >/dev/null 2>&1; then
        warn "  install LAN: the port-forward could not be added — use the admin VPN"
        return 0
    fi
    printf '%s\n' "${net}" > "${ALLOW_FILE}"
    systemctl restart tappaas-console.service 2>/dev/null \
        || warn "  install LAN: the console was not restarted — it accepts ${net} after its next start"
    info "  ${GN}✓${CL} install LAN: http://${wan_ip}:${CONSOLE_PORT}/ from ${net} only, with the setup token, until identity is installed"
}

cmd_open() {
    [[ -f "${CONFIG_DIR}/identity.json" ]] && { info "identity is installed — the console is at console.<domain>, behind the gate"; return 0; }
    local wan wan_ip="" bits=""
    wan="$(wan_of_firewall)"
    [[ -n "${wan}" ]] && read -r wan_ip bits <<<"${wan}"
    [[ -n "${wan_ip}" ]] || warn "  could not read the firewall's WAN address — the VPN config's Endpoint is a placeholder, and no install-LAN access"
    open_vpn_peer "${wan_ip}"
    [[ -n "${wan_ip}" ]] && open_lan "${wan_ip}" "${bits}"
    return 0
}

cmd_close() {
    local uuids u
    uuids="$(nat-manager list-rules --no-ssl-verify --json --search "${NAT_DESC}" 2>/dev/null \
        | jq -r --arg d "${NAT_DESC}" '.. | objects | select(.description? == $d) | .uuid // empty' 2>/dev/null)" || uuids=""
    for u in ${uuids}; do
        nat-manager delete-rule --no-ssl-verify --uuid "${u}" --no-apply >/dev/null 2>&1 || warn "  could not remove the install-LAN forward ${u}"
    done
    [[ -n "${uuids}" ]] && { nat-manager apply --no-ssl-verify >/dev/null 2>&1 || true; info "  ${GN}✓${CL} install-LAN forward to the console removed"; }
    if [[ -f "${ALLOW_FILE}" ]]; then
        rm -f "${ALLOW_FILE}"
        systemctl restart tappaas-console.service 2>/dev/null || true
        info "  ${GN}✓${CL} the console accepts the install LAN no more"
    fi
    return 0
}

cmd_status() {
    [[ -s "${PEER_CONF}" ]] && echo "admin VPN peer config: ${PEER_CONF}" || echo "admin VPN peer config: none"
    [[ -s "${ALLOW_FILE}" ]] && echo "install LAN: $(cat "${ALLOW_FILE}")" || echo "install LAN: closed"
}

case "${1:-}" in
    open)   cmd_open ;;
    close)  cmd_close ;;
    status) cmd_status ;;
    *)      echo "usage: $(basename "$0") open | close | status" >&2; exit 2 ;;
esac
