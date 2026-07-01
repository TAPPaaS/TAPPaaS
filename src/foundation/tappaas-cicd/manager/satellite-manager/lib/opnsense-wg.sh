#!/usr/bin/env bash
# lib/opnsense-wg.sh — home-side (OPNsense) WireGuard operations for the ADR-010
# satellite infra tunnel. Encodes the recipe validated live 2026-07-01.
#
# OPNsense terms: "server" = the home WG instance (local interface); "client" =
# the satellite peer (home dials out to it). The peer Endpoint is driven by
# serveraddress + serverport (NOT the inert `endpoint` field).
#
# Uses the OPNsense REST API directly (curl); creds from ~/.opnsense-credentials.txt
# (key=/secret= prefixed), :8443, self-signed (-k). WireGuard keys are generated
# with wg (via nix-shell wireguard-tools; OPNsense has no genKeys endpoint and
# addServer requires a real keypair).
#
# shellcheck shell=bash

OPNSENSE_CRED="${OPNSENSE_CRED:-$HOME/.opnsense-credentials.txt}"
OPNSENSE_HOST="${OPNSENSE_HOST:-firewall.mgmt.internal}"
OPNSENSE_PORT="${OPNSENSE_PORT:-8443}"

_ow_creds() {  # echoes "token:secret"
    local t s
    t="$(sed -n 1p "${OPNSENSE_CRED}" | sed 's/^key=//')"
    s="$(sed -n 2p "${OPNSENSE_CRED}" | sed 's/^secret=//')"
    printf '%s:%s' "${t}" "${s}"
}
_ow_api() {  # _ow_api <curl-args...> <path>
    local path="${!#}"; set -- "${@:1:$#-1}"
    curl -sk -u "$(_ow_creds)" "$@" "https://${OPNSENSE_HOST}:${OPNSENSE_PORT}${path}"
}

# Generate a WireGuard keypair -> echoes "PRIV PUB".
ow_genkey() {
    nix-shell -p wireguard-tools --run 'p=$(wg genkey); printf "%s %s" "$p" "$(printf %s "$p" | wg pubkey)"'
}

# Ensure the home WG server instance. Args: name tunneladdress-cidr(home) privkey pubkey
# Echoes the server UUID. (Create-only; assumes it does not yet exist.)
ow_add_server() {
    local name="$1" addr="$2" priv="$3" pub="$4"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"server\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"privkey\":\"${priv}\",\"tunneladdress\":\"${addr}\"}}" \
        /api/wireguard/server/addServer | jq -r '.uuid // empty'
}

# Set the server's peers list. Args: uuid name addr priv pub client-uuid
ow_link_server_peer() {
    local uuid="$1" name="$2" addr="$3" priv="$4" pub="$5" cli="$6"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"server\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"privkey\":\"${priv}\",\"tunneladdress\":\"${addr}\",\"peers\":\"${cli}\"}}" \
        "/api/wireguard/server/setServer/${uuid}" | jq -r '.result // empty'
}

# Add the satellite peer (client). Args: name sat-pubkey sat-ip wgport keepalive allowed-cidr server-uuid
# Echoes client UUID.
ow_add_client() {
    local name="$1" pub="$2" ip="$3" port="$4" ka="$5" allowed="$6" srv="$7"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"client\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"serveraddress\":\"${ip}\",\"serverport\":\"${port}\",\"keepalive\":\"${ka}\",\"tunneladdress\":\"${allowed}\",\"servers\":\"${srv}\"}}" \
        /api/wireguard/client/addClient | jq -r '.uuid // empty'
}

# Update an existing peer's pubkey (post-provision read-back). Args: client-uuid name sat-pubkey sat-ip wgport keepalive allowed server-uuid
ow_set_client_pubkey() {
    local cli="$1" name="$2" pub="$3" ip="$4" port="$5" ka="$6" allowed="$7" srv="$8"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"client\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"serveraddress\":\"${ip}\",\"serverport\":\"${port}\",\"keepalive\":\"${ka}\",\"tunneladdress\":\"${allowed}\",\"servers\":\"${srv}\"}}" \
        "/api/wireguard/client/setClient/${cli}" | jq -r '.result // empty'
}

ow_enable_and_apply() {
    _ow_api -X POST -H 'Content-Type: application/json' -d '{"general":{"enabled":"1"}}' /api/wireguard/general/set >/dev/null
    _ow_api -X POST /api/wireguard/service/reconfigure | jq -r '.result // empty'
}

# Peer handshake age (seconds) or "offline". Args: (none — single peer assumed)
ow_peer_status() {
    _ow_api /api/wireguard/service/show \
        | jq -r '.rows[] | select(.type=="peer") | "\(.["peer-status"]) hs=\(.["latest-handshake-age"])"' | head -1
}

ow_del_client() { _ow_api -X POST "/api/wireguard/client/delClient/$1" >/dev/null; }
ow_del_server() { _ow_api -X POST "/api/wireguard/server/delServer/$1" >/dev/null; }
