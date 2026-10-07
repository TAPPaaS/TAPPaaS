#!/usr/bin/env bash
# lib/opnsense-wg.sh — home-side (OPNsense) WireGuard operations, shared by the
# satellite module's infra tunnel and network-manager's admin VPN (wgvpn/).
# Encodes the recipe validated live 2026-07-01.
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

# ── several named instances per site (#796 backup-buddy tunnels) ─────────────
# The helpers above assume ONE server and ONE peer. A site with buddy tunnels has
# one instance per tunnel, so these find by name and update in place. setServer /
# setClient replace the whole record — a field left out is cleared (the port and
# MTU go to defaults, the peer list empties) — so updates read the record back,
# flatten OPNsense's select-objects to their selected keys, and re-send it.

ow_server_uuid() {
    _ow_api /api/wireguard/server/searchServer \
        | jq -r --arg n "$1" '.rows[]? | select(.name==$n) | .uuid' | head -1
}
ow_client_uuid() {
    _ow_api /api/wireguard/client/searchClient \
        | jq -r --arg n "$1" '.rows[]? | select(.name==$n) | .uuid' | head -1
}

# select-object {key:{value,selected}} -> "k1,k2" of the selected keys.
_OW_FLAT='with_entries(.value |= (if type=="object" then ([to_entries[] | select((.value.selected // 0)|tostring=="1") | .key] | join(",")) else . end))'
_OW_SERVER_FIELDS='["enabled","name","pubkey","privkey","port","mtu","dns","tunneladdress","disableroutes","gateway","peers"]'
_OW_CLIENT_FIELDS='["enabled","name","pubkey","psk","tunneladdress","serveraddress","serverport","keepalive","servers"]'

# The current record as flat JSON, limited to the settable fields.
_ow_record() {  # <server|client> <uuid>
    local kind="$1" uuid="$2" Kind fields
    Kind="$(tr '[:lower:]' '[:upper:]' <<<"${kind:0:1}")${kind:1}"
    [[ "${kind}" == "server" ]] && fields="${_OW_SERVER_FIELDS}" || fields="${_OW_CLIENT_FIELDS}"
    _ow_api "/api/wireguard/${kind}/get${Kind}/${uuid}" \
        | jq -c --argjson keep "${fields}" ".${kind} // {} | ${_OW_FLAT} | with_entries(select(.key as \$k | \$keep | index(\$k)))"
}

# Merge <overrides-json> into the record and write it back. Echoes the result.
ow_update() {  # <server|client> <uuid> <overrides-json>
    local kind="$1" uuid="$2" over="$3" Kind body
    Kind="$(tr '[:lower:]' '[:upper:]' <<<"${kind:0:1}")${kind:1}"
    body="$(_ow_record "${kind}" "${uuid}")" || return 1
    [[ -n "${body}" && "${body}" != "{}" ]] || { echo "no ${kind} ${uuid}" >&2; return 1; }
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "$(jq -c --argjson o "${over}" --arg k "${kind}" '{($k): (. + $o)}' <<<"${body}")" \
        "/api/wireguard/${kind}/set${Kind}/${uuid}" | jq -r '.result // empty'
}

# Ensure a named server instance (listen port, MTU). Creates it with a fresh
# keypair when missing; otherwise corrects address/port/MTU in place and keeps its
# key (a re-run must not invalidate the key the other site already holds).
# Echoes the server UUID.
ow_ensure_server() {  # <name> <tunneladdress-cidr> <port> [mtu]
    local name="$1" addr="$2" port="$3" mtu="${4:-}" uuid kp priv pub
    uuid="$(ow_server_uuid "${name}")"
    if [[ -n "${uuid}" ]]; then
        ow_update server "${uuid}" "$(jq -nc --arg a "${addr}" --arg p "${port}" --arg m "${mtu}" \
            '{enabled:"1",tunneladdress:$a,port:$p,mtu:$m}')" >/dev/null
        echo "${uuid}"; return 0
    fi
    kp="$(ow_genkey)"; priv="${kp% *}"; pub="${kp#* }"
    [[ -n "${priv}" && -n "${pub}" ]] || { echo "ow_ensure_server: key generation failed" >&2; return 1; }
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg n "${name}" --arg a "${addr}" --arg p "${port}" --arg m "${mtu}" \
            --arg priv "${priv}" --arg pub "${pub}" \
            '{server:{enabled:"1",name:$n,pubkey:$pub,privkey:$priv,port:$p,mtu:$m,tunneladdress:$a}}')" \
        /api/wireguard/server/addServer | jq -r '.uuid // empty'
}

ow_server_pubkey_of() {  # <uuid>
    _ow_api "/api/wireguard/server/getServer/$1" | jq -r '.server.pubkey // empty'
}

# Ensure a named peer bound to one server and make it that server's peer list.
# endpoint-host/port empty = the peer dials us (no Endpoint). Echoes client UUID.
ow_ensure_client() {  # <name> <pubkey> <allowed-cidr> <server-uuid> [endpoint-host] [endpoint-port] [keepalive]
    local name="$1" pub="$2" allowed="$3" srv="$4" host="${5:-}" port="${6:-}" ka="${7:-}" cli rec
    rec="$(jq -nc --arg n "${name}" --arg k "${pub}" --arg a "${allowed}" --arg s "${srv}" \
        --arg h "${host}" --arg p "${port}" --arg ka "${ka}" \
        '{enabled:"1",name:$n,pubkey:$k,tunneladdress:$a,servers:$s,serveraddress:$h,serverport:$p,keepalive:$ka}')"
    cli="$(ow_client_uuid "${name}")"
    if [[ -z "${cli}" ]]; then
        cli="$(_ow_api -X POST -H 'Content-Type: application/json' -d "{\"client\":${rec}}" \
            /api/wireguard/client/addClient | jq -r '.uuid // empty')"
        [[ -n "${cli}" ]] || { echo "ow_ensure_client: addClient ${name} failed" >&2; return 1; }
    else
        ow_update client "${cli}" "${rec}" >/dev/null
    fi
    ow_update server "${srv}" "{\"peers\":\"${cli}\"}" >/dev/null
    echo "${cli}"
}

# Handshake state of the peer with <pubkey>: "<status> hs=<age>", or nothing.
ow_peer_status_of() {  # <pubkey>
    _ow_api /api/wireguard/service/show \
        | jq -r --arg k "$1" '.rows[]? | select(.type=="peer" and ((.["public-key"] // .pubkey // "")==$k))
            | "\(.["peer-status"] // "unknown") hs=\(.["latest-handshake-age"] // "never")"' | head -1
}
