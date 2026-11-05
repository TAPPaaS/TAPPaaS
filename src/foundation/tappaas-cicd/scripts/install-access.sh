#!/usr/bin/env bash
#
# install-access.sh — reach the console right after the bootstrap, to continue the
# install from the web (ADR-037 D3).
#
# The console runs on the mothership from the moment install.sh ends, unlocked by
# its setup token from mgmt and the admin VPN only, until the first installer
# signs in through the Authentik gate at console.<domain>.
# The operator who ran the bootstrap sits on neither. No VPN peer is made for
# them: they enrol their own device in Day 1's admin VPN step, at home as on a
# hosted server. Until then `open` gives one way in:
#
#   - On a PRIVATE WAN subnet (the install LAN at home, never the internet): a
#     port-forward of the firewall's WAN address, port 9097, to the console, from
#     that subnet alone, and the subnet added to what the console accepts with the
#     setup token (config/console-setup-allow).
#   - On a PUBLIC WAN nothing is opened: the operator reaches the console through
#     an ssh tunnel to the node (`ssh -L 9097:<mothership>:9097 root@<node>`),
#     arriving from mgmt. The install's end note gives the command.
#
# `close` removes the forward and the extra allow: the console runs it at that
# first sign-in, when it also deletes the setup token.
#
# `reopen` is the way back for a site where setup closed with nobody able to sign
# in: a new setup token, and the same ways in. The next sign-in through the gate
# closes it again. From a shell on the mothership only.
#
# Usage: install-access.sh open | close | reopen | status
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
FW_HOST="${INSTALL_ACCESS_FIREWALL:-root@firewall.mgmt.internal}"
FW_KEY="${HOME}/.ssh/tappaas-fw"
CONSOLE_PORT=9097
NAT_DESC="TAPPaaS: console (install LAN, until identity)"
TOKEN_FILE="${CONFIG_DIR}/console-setup-token"
ALLOW_FILE="${CONFIG_DIR}/console-setup-allow"
URL_FILE="${CONFIG_DIR}/console-setup-url"

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

open_lan() {
    local wan_ip="$1" bits="$2" net cicd
    net="$(network_of "${wan_ip}" "${bits}")"
    if ! is_private "${net}"; then
        info "  the WAN (${net}) is public: no install-LAN access — reach the console through an ssh tunnel to the node"
        return 0
    fi
    cicd="$(cicd_mgmt_ip)"
    [[ -n "${cicd}" ]] || { warn "  install LAN: the mothership has no mgmt address — skipped"; return 0; }
    if ! nat-manager add-rule --no-ssl-verify --description "${NAT_DESC}" --external-port "${CONSOLE_PORT}" \
            --target "${cicd}" --internal-port "${CONSOLE_PORT}" --protocol TCP --interface wan \
            --source "${net}" >/dev/null 2>&1; then
        warn "  install LAN: the port-forward could not be added — reach the console through an ssh tunnel to the node"
        return 0
    fi
    printf '%s\n' "${net}" > "${ALLOW_FILE}"
    printf 'http://%s:%s/setup/day1\n' "${wan_ip}" "${CONSOLE_PORT}" > "${URL_FILE}"
    systemctl restart tappaas-console.service 2>/dev/null \
        || warn "  install LAN: the console was not restarted — it accepts ${net} after its next start"
    info "  ${GN}✓${CL} install LAN: http://${wan_ip}:${CONSOLE_PORT}/ from ${net} only, with the setup token, until the first sign-in through the gate"
}

cmd_open() {
    local wan wan_ip="" bits=""
    wan="$(wan_of_firewall)"
    [[ -n "${wan}" ]] && read -r wan_ip bits <<<"${wan}"
    if [[ -z "${wan_ip}" ]]; then
        warn "  could not read the firewall's WAN address — no install-LAN access; reach the console through an ssh tunnel to the node"
        return 0
    fi
    open_lan "${wan_ip}" "${bits}"
    return 0
}

cmd_reopen() {
    if [[ ! -s "${TOKEN_FILE}" ]]; then
        ( umask 077 && head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${TOKEN_FILE}" )
        info "  ${GN}✓${CL} a new setup token: ${TOKEN_FILE}"
    fi
    cmd_close
    cmd_open
}

cmd_close() {
    local uuids u
    uuids="$(nat-manager list-rules --no-ssl-verify --json --search "${NAT_DESC}" 2>/dev/null \
        | jq -r --arg d "${NAT_DESC}" '.. | objects | select(.description? == $d) | .uuid // empty' 2>/dev/null)" || uuids=""
    for u in ${uuids}; do
        nat-manager delete-rule --no-ssl-verify --uuid "${u}" --no-apply >/dev/null 2>&1 || warn "  could not remove the install-LAN forward ${u}"
    done
    [[ -n "${uuids}" ]] && { nat-manager apply --no-ssl-verify >/dev/null 2>&1 || true; info "  ${GN}✓${CL} install-LAN forward to the console removed"; }
    rm -f "${URL_FILE}"
    if [[ -f "${ALLOW_FILE}" ]]; then
        rm -f "${ALLOW_FILE}"
        systemctl restart tappaas-console.service 2>/dev/null || true
        info "  ${GN}✓${CL} the console accepts the install LAN no more"
    fi
    return 0
}

cmd_status() {
    [[ -s "${ALLOW_FILE}" ]] && echo "install LAN: $(cat "${ALLOW_FILE}")" || echo "install LAN: closed"
}

case "${1:-}" in
    open)   cmd_open ;;
    close)  cmd_close ;;
    reopen) cmd_reopen ;;
    status) cmd_status ;;
    *)      echo "usage: $(basename "$0") open | close | reopen | status" >&2; exit 2 ;;
esac
