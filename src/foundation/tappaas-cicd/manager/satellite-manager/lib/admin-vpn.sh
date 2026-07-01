#!/usr/bin/env bash
# lib/admin-vpn.sh — OPNsense admin-vpn termination (ADR-010 §6, implementation Q3).
#
# Terminates the operator's admin WireGuard session ON OPNsense (a dedicated WG
# server instance) and routes it into the `mgmt` zone via one least-privilege
# firewall rule. This is identical whether the session arrives:
#   • via a satellite blind-relay  (admin device Endpoint = <satellite-ip>:51821), or
#   • direct to the cluster WAN     (admin device Endpoint = <cluster-public-ip>:51821).
# The satellite only relays UDP; OPNsense is always the terminator (§6.1).
#
# Reuses opnsense-wg.sh's curl/creds/keygen helpers. All operations are
# idempotent (find-by-name / find-by-description before create).
# Validated live 2026-07-01 (server + peer handshake + admin->mgmt rule).
#
# shellcheck shell=bash
# shellcheck source=/dev/null
_here_av="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here_av}/opnsense-wg.sh"

: "${SAT_ADMIN_WGPORT:=51821}"          # OPNsense admin-WG listen port
: "${AV_SERVER_NAME:=tappaas-admin}"    # WG server instance name
: "${AV_TUNNEL_ADDR:=10.255.1.1/24}"    # admin overlay gateway (OPNsense end)
: "${AV_PEER_SUBNET:=10.255.1.0/24}"    # admin overlay zone (source)
: "${AV_MGMT_SUBNET:=10.0.0.0/24}"      # management plane (destination)
: "${AV_WG_IFACE:=wireguard}"           # OPNsense WireGuard group interface token
: "${AV_RULE_DESC:=tappaas-admin admin->mgmt}"
: "${AV_KEEPALIVE:=25}"

# ── WG server instance ───────────────────────────────────────────────────────
av_server_uuid() {
    _ow_api /api/wireguard/server/searchServer \
        | jq -r --arg n "${AV_SERVER_NAME}" '.rows[]? | select(.name==$n) | .uuid' | head -1
}

# Ensure the admin WG server exists (create with a fresh keypair if missing).
# Echoes the server UUID.
av_ensure_server() {
    local uuid; uuid="$(av_server_uuid)"
    if [[ -n "${uuid}" ]]; then echo "${uuid}"; return 0; fi
    local kp priv pub; kp="$(ow_genkey)"; priv="${kp% *}"; pub="${kp#* }"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"server\":{\"enabled\":\"1\",\"name\":\"${AV_SERVER_NAME}\",\"pubkey\":\"${pub}\",\"privkey\":\"${priv}\",\"port\":\"${SAT_ADMIN_WGPORT}\",\"tunneladdress\":\"${AV_TUNNEL_ADDR}\"}}" \
        /api/wireguard/server/addServer | jq -r '.uuid // empty'
}

# The admin server's PUBLIC key (hand this to admin devices as [Peer] PublicKey).
av_server_pubkey() {
    local uuid="${1:-$(av_server_uuid)}"
    [[ -n "${uuid}" ]] || return 1
    _ow_api "/api/wireguard/server/getServer/${uuid}" | jq -r '.server.pubkey // empty'
}

# Re-link the server's peer list to every admin-overlay client (idempotent).
# getServer returns select-objects; setServer wants a comma-separated UUID list.
av_relink_peers() {
    local uuid="${1:-$(av_server_uuid)}" body name priv pub taddr peers
    body="$(_ow_api "/api/wireguard/server/getServer/${uuid}")"
    name="$(jq -r '.server.name' <<<"${body}")"
    priv="$(jq -r '.server.privkey' <<<"${body}")"
    pub="$(jq -r '.server.pubkey' <<<"${body}")"
    taddr="$(jq -r '.server.tunneladdress | if type=="object" then (to_entries|map(select(.value.selected==1))|.[0].key) else . end' <<<"${body}")"
    peers="$(_ow_api /api/wireguard/client/searchClient \
        | jq -r --arg net "${AV_PEER_SUBNET%.*/*}." '[.rows[]? | select((.tunneladdress//"")|startswith($net)) | .uuid] | join(",")')"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"server\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"privkey\":\"${priv}\",\"port\":\"${SAT_ADMIN_WGPORT}\",\"tunneladdress\":\"${taddr}\",\"peers\":\"${peers}\"}}" \
        "/api/wireguard/server/setServer/${uuid}" | jq -r '.result // empty'
}

# ── admin peers (inbound admin devices) ──────────────────────────────────────
av_peer_uuid() {
    _ow_api /api/wireguard/client/searchClient \
        | jq -r --arg n "$1" '.rows[]? | select(.name==$n) | .uuid' | head -1
}

# Next free host in the admin overlay (…/24), starting at .2 (…1 is OPNsense).
av_next_ip() {
    local base="${AV_PEER_SUBNET%.*}." used i
    used="$(_ow_api /api/wireguard/client/searchClient \
        | jq -r '.rows[]?.tunneladdress // empty' | sed 's#/.*##' | awk -F. '{print $NF}')"
    for i in $(seq 2 254); do grep -qx "${i}" <<<"${used}" || { echo "${base}${i}/32"; return 0; }; done
    return 1
}

# Add or update an admin peer. Args: <name> <pubkey> [ip/32]
# Echoes the assigned tunnel address.
av_add_peer() {
    local name="$1" pub="$2" ip="${3:-}" srv cli
    srv="$(av_ensure_server)"
    [[ -n "${ip}" ]] || ip="$(av_next_ip)"
    cli="$(av_peer_uuid "${name}")"
    if [[ -z "${cli}" ]]; then
        _ow_api -X POST -H 'Content-Type: application/json' \
            -d "{\"client\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"keepalive\":\"${AV_KEEPALIVE}\",\"tunneladdress\":\"${ip}\",\"servers\":\"${srv}\"}}" \
            /api/wireguard/client/addClient >/dev/null
    else
        _ow_api -X POST -H 'Content-Type: application/json' \
            -d "{\"client\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"keepalive\":\"${AV_KEEPALIVE}\",\"tunneladdress\":\"${ip}\",\"servers\":\"${srv}\"}}" \
            "/api/wireguard/client/setClient/${cli}" >/dev/null
    fi
    av_relink_peers "${srv}" >/dev/null
    echo "${ip}"
}

av_remove_peer() {
    local cli; cli="$(av_peer_uuid "$1")"
    [[ -n "${cli}" ]] || { echo "no such peer: $1" >&2; return 1; }
    ow_del_client "${cli}"
    av_relink_peers >/dev/null
}

# ── firewall: admin overlay -> mgmt (the Q3 routing rule) ─────────────────────
av_rule_uuid() {
    _ow_api /api/firewall/filter/searchRule \
        | jq -r --arg d "${AV_RULE_DESC}" '.rows[]? | select(.description==$d) | .uuid' | head -1
}

# Ensure the pass rule admin(10.255.1.0/24) -> mgmt(10.0.0.0/24) on the WG iface.
av_ensure_mgmt_rule() {
    local uuid; uuid="$(av_rule_uuid)"
    if [[ -n "${uuid}" ]]; then echo "exists"; return 0; fi
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"rule\":{\"enabled\":\"1\",\"action\":\"pass\",\"interface\":\"${AV_WG_IFACE}\",\"direction\":\"in\",\"ipprotocol\":\"inet\",\"protocol\":\"any\",\"source_net\":\"${AV_PEER_SUBNET}\",\"destination_net\":\"${AV_MGMT_SUBNET}\",\"description\":\"${AV_RULE_DESC}\"}}" \
        /api/firewall/filter/addRule | jq -r '.result // empty'
}

# ── apply ────────────────────────────────────────────────────────────────────
av_apply() {
    _ow_api -X POST -H 'Content-Type: application/json' -d '{"general":{"enabled":"1"}}' /api/wireguard/general/set >/dev/null
    _ow_api -X POST /api/wireguard/service/reconfigure >/dev/null
    _ow_api -X POST /api/firewall/filter/apply >/dev/null
    echo "applied"
}

# Full idempotent bring-up of the OPNsense termination (no peers yet).
av_setup() {
    local srv; srv="$(av_ensure_server)"
    [[ -n "${srv}" ]] || { echo "ERROR: could not ensure admin WG server" >&2; return 1; }
    av_ensure_mgmt_rule >/dev/null
    av_apply >/dev/null
    echo "admin-vpn ready: server=${AV_SERVER_NAME} port=${SAT_ADMIN_WGPORT} pubkey=$(av_server_pubkey "${srv}")"
    echo "  rule: ${AV_PEER_SUBNET} -> ${AV_MGMT_SUBNET} (interface ${AV_WG_IFACE})"
}

# Emit a ready-to-use client config for an admin device.
# Args: <peer-tunnel-ip/32> <endpoint-host:port> [private-key-or-PLACEHOLDER]
av_client_config() {
    local ip="$1" endpoint="$2" priv="${3:-<PASTE-YOUR-PRIVATE-KEY>}" srvpub
    srvpub="$(av_server_pubkey)"
    cat <<EOF
[Interface]
PrivateKey = ${priv}
Address    = ${ip}
MTU        = 1340

[Peer]
PublicKey           = ${srvpub}
Endpoint            = ${endpoint}
AllowedIPs          = ${AV_MGMT_SUBNET}
PersistentKeepalive = ${AV_KEEPALIVE}
EOF
}

av_list() {
    local srv; srv="$(av_server_uuid)"
    echo "server : ${AV_SERVER_NAME} (uuid=${srv:-<none>}) port=${SAT_ADMIN_WGPORT}"
    [[ -n "${srv}" ]] && echo "pubkey : $(av_server_pubkey "${srv}")"
    echo "rule   : $([[ -n "$(av_rule_uuid)" ]] && echo present || echo MISSING) (${AV_PEER_SUBNET} -> ${AV_MGMT_SUBNET})"
    echo "peers  :"
    _ow_api /api/wireguard/client/searchClient \
        | jq -r --arg net "${AV_PEER_SUBNET%.*/*}." '.rows[]? | select((.tunneladdress//"")|startswith($net)) | "  - \(.name)  \(.tunneladdress)"'
}
