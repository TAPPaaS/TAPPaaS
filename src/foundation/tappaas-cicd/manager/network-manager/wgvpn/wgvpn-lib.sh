#!/usr/bin/env bash
# wgvpn/wgvpn-lib.sh — the admin VPN's OPNsense side (ADR-010 §6, §8.4.6).
#
# Terminates the operator's admin WireGuard session ON OPNsense (a dedicated WG
# server instance) and routes it into the `mgmt` zone via one least-privilege
# firewall rule. This is identical whether the session arrives:
#   • via a satellite blind-relay  (admin device Endpoint = <satellite-ip>:51821), or
#   • direct to the cluster WAN     (admin device Endpoint = <cluster-public-ip>:51821).
# The satellite only relays UDP; OPNsense is always the terminator (§6.1). That is
# why this lives with network-manager (`network-manager wgvpn`), not the satellite.
#
# Reuses lib/opnsense-wg.sh's curl/creds/keygen helpers. All operations are
# idempotent (find-by-name / find-by-description before create).
# Validated live 2026-07-01 (server + peer handshake + admin->mgmt rule).
#
# shellcheck shell=bash
# shellcheck source=/dev/null
_here_av="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here_av}/../../../lib/opnsense-wg.sh"

: "${SAT_ADMIN_WGPORT:=51821}"          # admin-WG listen port of a NEW instance (av_server_port)
: "${AV_SERVER_NAME:=tappaas-admin}"    # WG server instance name
: "${AV_TUNNEL_ADDR:=10.255.1.1/24}"    # admin overlay gateway (OPNsense end)
: "${AV_PEER_SUBNET:=10.255.1.0/24}"    # admin overlay zone (source)
: "${AV_MGMT_SUBNET:=10.0.0.0/24}"      # management plane (destination)
: "${AV_WG_IFACE:=wireguard}"           # OPNsense WireGuard group interface token
: "${AV_WAN_IFACE:=wan}"                # OPNsense WAN interface token
: "${AV_RULE_DESC:=tappaas-admin admin->mgmt}"
: "${AV_KEEPALIVE:=25}"

# ── WG server instance ───────────────────────────────────────────────────────
av_server_uuid() {
    _ow_api /api/wireguard/server/searchServer \
        | jq -r --arg n "${AV_SERVER_NAME}" '.rows[]? | select(.name==$n) | .uuid' | head -1
}

# The port the admin server listens on, read from the instance. An instance an
# earlier bootstrap or the operator made can listen on another port than the one
# setup gives a new one (hrossen: 51820), and the WAN rule and the peers' Endpoint
# must follow the instance. SAT_ADMIN_WGPORT while there is no instance.
av_server_port() {
    local p
    p="$(_ow_api /api/wireguard/server/searchServer 2>/dev/null \
        | jq -r --arg n "${AV_SERVER_NAME}" '.rows[]? | select(.name==$n) | .port // empty' 2>/dev/null | head -1)"
    if [[ "${p}" =~ ^[0-9]+$ ]]; then printf '%s\n' "${p}"; else printf '%s\n' "${SAT_ADMIN_WGPORT}"; fi
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
# The instance keeps its own port: setServer writes every field it is given.
av_relink_peers() {
    local uuid="${1:-$(av_server_uuid)}" body name priv pub taddr peers port
    body="$(_ow_api "/api/wireguard/server/getServer/${uuid}")"
    name="$(jq -r '.server.name' <<<"${body}")"
    port="$(jq -r '.server.port // empty' <<<"${body}")"
    [[ "${port}" =~ ^[0-9]+$ ]] || port="${SAT_ADMIN_WGPORT}"
    priv="$(jq -r '.server.privkey' <<<"${body}")"
    pub="$(jq -r '.server.pubkey' <<<"${body}")"
    taddr="$(jq -r '.server.tunneladdress | if type=="object" then (to_entries|map(select(.value.selected==1))|.[0].key) else . end' <<<"${body}")"
    peers="$(_ow_api /api/wireguard/client/searchClient \
        | jq -r --arg net "${AV_PEER_SUBNET%.*/*}." '[.rows[]? | select((.tunneladdress//"")|startswith($net)) | .uuid] | join(",")')"
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"server\":{\"enabled\":\"1\",\"name\":\"${name}\",\"pubkey\":\"${pub}\",\"privkey\":\"${priv}\",\"port\":\"${port}\",\"tunneladdress\":\"${taddr}\",\"peers\":\"${peers}\"}}" \
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
#
# Filter rules go through the opnsense-controller CLI (`opnsense-firewall
# create-rule`) so every TAPPaaS firewall rule shares ONE code path — the Python
# FirewallManager: idempotent by description, validated, and unit-tested — instead
# of a second, hand-rolled REST path. Same pattern setup-caddy.sh uses for the
# WAN :80/:443 rules. WireGuard server/peer objects have no controller binding, so
# those stay on _ow_api. Raw REST remains here only as a fallback when the CLI is
# unavailable (mirrors setup-caddy's SSH/PHP fallback), keeping bootstrap robust.

# Locate the controller firewall CLI; echo its path, or nothing if unavailable.
av_fw_cli() {
    local c="/home/tappaas/bin/opnsense-firewall"
    [[ -x "${c}" ]] || c="$(command -v opnsense-firewall 2>/dev/null || true)"
    [[ -n "${c}" && -x "${c}" ]] && printf '%s' "${c}"
}

av_rule_uuid() {
    _ow_api /api/firewall/filter/searchRule \
        | jq -r --arg d "${AV_RULE_DESC}" '.rows[]? | select(.description==$d) | .uuid' | head -1
}

# Ensure the pass rule admin(10.255.1.0/24) -> mgmt(10.0.0.0/24) on the WG iface.
av_ensure_mgmt_rule() {
    local cli err; cli="$(av_fw_cli)"
    if [[ -n "${cli}" ]]; then
        # Pin --port to the same value the raw-REST path uses (opnsense-wg.sh's
        # OPNSENSE_PORT, default 8443). Without it the CLI auto-detects, probing
        # 443 first and latching onto whatever answers a TLS handshake there —
        # during bootstrap os-caddy binds :443, so the probe returns Caddy's port,
        # never the API, and every call fails. That port drift from the REST path
        # is #418. Capture stderr and surface it on failure so it stays diagnosable.
        if err="$("${cli}" create-rule --firewall "${OPNSENSE_HOST}" --port "${OPNSENSE_PORT}" --no-ssl-verify \
            --description "${AV_RULE_DESC}" --interface "${AV_WG_IFACE}" \
            --action pass --protocol any --no-log \
            --source "${AV_PEER_SUBNET}" --destination "${AV_MGMT_SUBNET}" \
            --no-apply 2>&1)"; then echo "ok"; return 0; fi
        echo "opnsense-firewall create-rule (admin->mgmt) failed; falling back to raw REST: ${err}" >&2
    fi
    local uuid; uuid="$(av_rule_uuid)"
    if [[ -n "${uuid}" ]]; then echo "exists"; return 0; fi
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"rule\":{\"enabled\":\"1\",\"action\":\"pass\",\"interface\":\"${AV_WG_IFACE}\",\"direction\":\"in\",\"ipprotocol\":\"inet\",\"protocol\":\"any\",\"source_net\":\"${AV_PEER_SUBNET}\",\"destination_net\":\"${AV_MGMT_SUBNET}\",\"description\":\"${AV_RULE_DESC}\"}}" \
        /api/firewall/filter/addRule | jq -r '.result // empty'
}

# The description a WAN rule for <port> is created with.
av_wan_rule_desc() { printf '%s' "${AV_WAN_RULE_DESC:-tappaas-admin WAN :$1}"; }

# The WAN pass rule for the admin listener on <port>, found by what it does (an
# enabled pass for UDP to that port on the WAN), not by its description, which
# names the port it was made for. Echoes "uuid<TAB>description", or nothing.
av_wan_rule() {
    _ow_api /api/firewall/filter/searchRule | jq -r --arg p "$1" --arg i "${AV_WAN_IFACE}" '
        .rows[]? | select(((.interface // "") | split(",") | index($i)) != null
            and ((.protocol // "") | ascii_upcase) == "UDP" and (.destination_port // "") == $p
            and .action == "pass" and (.enabled // "1") == "1")
        | "\(.uuid)\t\(.description // "")"' 2>/dev/null | head -1
}

av_wan_rule_uuid() { av_wan_rule "${1:-$(av_server_port)}" | cut -f1; }

# Ensure a WAN pass rule for the admin-WG listener: UDP :<port> -> This Firewall.
# Safe to open unconditionally — WireGuard silently drops any packet not
# authenticated by a registered peer key (no handshake, no response, no banner),
# so an exposed port is inert until a device is enrolled. Consequences by site:
#   • CGNAT / no inbound (Topology A): the rule is never reached — zero exposure.
#   • public IP (Topology B): gives direct reach with no manual WAN rule step.
# That is why bootstrap opens it (ADR-010 §6). The satellite is never required for
# the termination to exist; it only relays UDP for CGNAT sites.
# Arg: the instance's port (default SAT_ADMIN_WGPORT, the port of a new one).
av_ensure_wan_rule() {
    local port="${1:-${SAT_ADMIN_WGPORT}}" desc cli err; cli="$(av_fw_cli)"
    desc="$(av_wan_rule_desc "${port}")"
    if [[ -n "${cli}" ]]; then
        # See av_ensure_mgmt_rule: pin --port (== OPNSENSE_PORT) so the CLI does not
        # auto-detect onto Caddy's :443, and surface stderr on failure (#418).
        if err="$("${cli}" create-rule --firewall "${OPNSENSE_HOST}" --port "${OPNSENSE_PORT}" --no-ssl-verify \
            --description "${desc}" --interface "${AV_WAN_IFACE}" \
            --action pass --protocol udp --log \
            --source any --destination wanip --destination-port "${port}" \
            --no-apply 2>&1)"; then echo "ok"; return 0; fi
        echo "opnsense-firewall create-rule (WAN :${port}) failed; falling back to raw REST: ${err}" >&2
    fi
    local uuid; uuid="$(av_wan_rule_uuid "${port}")"
    if [[ -n "${uuid}" ]]; then echo "exists"; return 0; fi
    _ow_api -X POST -H 'Content-Type: application/json' \
        -d "{\"rule\":{\"enabled\":\"1\",\"action\":\"pass\",\"interface\":\"${AV_WAN_IFACE}\",\"direction\":\"in\",\"ipprotocol\":\"inet\",\"protocol\":\"UDP\",\"source_net\":\"any\",\"destination_net\":\"wanip\",\"destination_port\":\"${port}\",\"description\":\"${desc}\"}}" \
        /api/firewall/filter/addRule | jq -r '.result // empty'
}

# ── apply ────────────────────────────────────────────────────────────────────
# Enable WireGuard and reconfigure the service. This is also what makes OPNsense
# register the `wireguard` GROUP INTERFACE — which a filter rule bound to
# ${AV_WG_IFACE} needs to already exist. Split out of av_apply so av_setup can run
# it BEFORE creating that rule (see av_setup).
av_enable_wg() {
    _ow_api -X POST -H 'Content-Type: application/json' -d '{"general":{"enabled":"1"}}' /api/wireguard/general/set >/dev/null
    _ow_api -X POST /api/wireguard/service/reconfigure >/dev/null
    echo "enabled"
}

av_apply() {
    av_enable_wg >/dev/null
    _ow_api -X POST /api/firewall/filter/apply >/dev/null
    echo "applied"
}

# Full idempotent bring-up of the OPNsense termination (no peers yet).
av_setup() {
    local srv port; srv="$(av_ensure_server)"
    [[ -n "${srv}" ]] || { echo "ERROR: could not ensure admin WG server" >&2; return 1; }
    port="$(av_server_port)"

    # Enable + reconfigure WireGuard FIRST. OPNsense only registers the
    # `wireguard` group interface once the service is up, and a filter rule bound
    # to an unregistered interface is rejected. Creating the rule before this ran
    # is why a first bootstrap left `wan` present but `admin->mgmt` MISSING (the
    # WAN rule targets `wan`, which always exists), while a manual re-run worked.
    av_enable_wg >/dev/null

    # Neither ensure path can report failure reliably: _ow_api is `curl -sk` (no
    # -f), so an OPNsense error response is exit 0 with an error body, and the raw
    # REST fallback ends in `| jq -r`, whose status is jq's. So do not trust their
    # exit codes -- verify observed state below instead.
    av_ensure_mgmt_rule >/dev/null || true
    av_ensure_wan_rule "${port}" >/dev/null || true
    av_apply >/dev/null

    # Verify against the LIVE rule set rather than asserting what we intended.
    # This is what `admin list` already does, and what makes install.sh's
    # `|| warn "admin-vpn setup encountered issues"` guard reachable at all.
    local missing=()
    [[ -n "$(av_rule_uuid)" ]]     || missing+=("admin->mgmt (${AV_PEER_SUBNET} -> ${AV_MGMT_SUBNET}, interface ${AV_WG_IFACE})")
    [[ -n "$(av_wan_rule_uuid "${port}")" ]] || missing+=("WAN UDP ${port} -> This Firewall (interface ${AV_WAN_IFACE})")

    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: admin-vpn setup incomplete -- server is up but these rules are absent:" >&2
        local m; for m in "${missing[@]}"; do echo "  - ${m}" >&2; done
        echo "The tunnel would handshake and then reach nothing. Re-run 'network-manager wgvpn setup'," >&2
        echo "then confirm with 'network-manager wgvpn list'." >&2
        return 1
    fi

    echo "admin-vpn ready: server=${AV_SERVER_NAME} port=${port} pubkey=$(av_server_pubkey "${srv}")"
    echo "  rule: ${AV_PEER_SUBNET} -> ${AV_MGMT_SUBNET} (interface ${AV_WG_IFACE})"
    echo "  wan : UDP ${port} -> This Firewall (interface ${AV_WAN_IFACE}) — direct/Topology-B reach"
}

# ── the client config (#856) ────────────────────────────────────────────────
#
# Besides mgmt, the peer is given the site's resolver and host routes to the
# DMZ gateway. Inside the site every published name (console.<domain>,
# logging.<domain>, …) answers with the DMZ gateway, where Caddy listens
# (ADR-021 D2), and the admin overlay may reach the firewall there on 80 and 443
# (ADR-021 D3a). Without the two, a laptop on the tunnel resolved a published
# name publicly, went to the WAN over the internet, and Caddy answered 403.
# The addresses come from zones.json: a zone's gateway is the first address of
# its `ip`. The IPv6 one is the firewall's own address on the dmz interface —
# what the published names' AAAA records point at (ADR-030 D9) — read from the
# firewall, since with a dynamic WAN it is formed from the interface's MAC.
#
# A config is versioned: 1 is mgmt only (before #856), 2 adds DNS and the DMZ
# routes. Every config add-peer or config prints is recorded under the peer's
# name, so `list` can say which peers still hold a version-1 tunnel.
readonly AV_CONFIG_VERSION=2

av_config_dir() { printf '%s' "${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"; }
av_zones_file() { printf '%s' "${AV_ZONES_FILE:-$(av_config_dir)/zones.json}"; }
av_issued_file() { printf '%s' "${AV_ISSUED_FILE:-$(av_config_dir)/wgvpn/peers.json}"; }

# A zone's IPv4 network, as zones.json has it (empty when the zone is absent).
av_zone_net() {
    jq -r --arg z "$1" '.[$z].ip // empty' "$(av_zones_file)" 2>/dev/null
}

# The first host address of an IPv4 network: a zone's gateway. Arg: a.b.c.d/n
av_first_host() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local n=$(( (10#${BASH_REMATCH[1]} << 24) | (10#${BASH_REMATCH[2]} << 16) | (10#${BASH_REMATCH[3]} << 8) | 10#${BASH_REMATCH[4]} ))
    local len=$(( 10#${BASH_REMATCH[5]} ))
    (( len >= 1 && len <= 30 )) || return 1
    n=$(( (n & ((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF)) + 1 ))
    printf '%d.%d.%d.%d\n' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) $(( n >> 8 & 255 )) $(( n & 255 ))
}

# The firewall's global IPv6 address on the interface whose IPv4 is <ip>, or
# nothing (link-local and ULA addresses are not what a published name gets).
av_iface_v6() {
    _ow_api /api/interfaces/overview/interfacesInfo 2>/dev/null | jq -r --arg ip "$1" '
        .rows[]? | select(any(.ipv4[]?; (.ipaddr // "" | split("/")[0]) == $ip))
        | .ipv6[]? | .ipaddr // "" | split("/")[0]
        | select(. != "" and (test("^(fe[89ab]|f[cd])"; "i") | not))' 2>/dev/null | head -1
}

# What the config carries besides the peer's own lines, as shell assignments:
#   av_dns  the site's resolver (mgmt's gateway)
#   av_allowed  mgmt, the DMZ gateway /32 and its IPv6 /128
#   av_note  why the IPv6 route is missing, when it is
av_routes() {
    local mgmt dmz gw6
    av_note=""
    mgmt="$(av_zone_net mgmt)"
    [[ -n "${mgmt}" ]] || { echo "[Warning] no mgmt zone in $(av_zones_file); using ${AV_MGMT_SUBNET}" >&2; mgmt="${AV_MGMT_SUBNET}"; }
    av_dns="$(av_first_host "${mgmt}")" || av_dns=""
    av_allowed="${mgmt}"
    dmz="$(av_zone_net dmz)"
    if [[ -z "${dmz}" ]] || ! av_dmz="$(av_first_host "${dmz}")"; then
        echo "[Warning] no dmz zone in $(av_zones_file): the config has no route to the published names" >&2
        return 0
    fi
    av_allowed+=", ${av_dmz}/32"
    if ! jq -e '.dmz.ipv6Subnet | type == "number"' "$(av_zones_file)" >/dev/null 2>&1; then
        av_note="no IPv6 route: the dmz zone has no ipv6Subnet, so the published names have no AAAA"
    elif gw6="$(av_iface_v6 "${av_dmz}")" && [[ -n "${gw6}" ]]; then
        av_allowed+=", ${gw6}/128"
    else
        av_note="no IPv6 route: the firewall's dmz interface (${av_dmz}) has no global IPv6 address"
    fi
}

# Emit a ready-to-use client config for an admin device.
# Args: <peer-tunnel-ip/32> <endpoint-host:port> [private-key-or-PLACEHOLDER]
av_client_config() {
    local ip="$1" endpoint="$2" priv="${3:-<PASTE-YOUR-PRIVATE-KEY>}" srvpub av_dns="" av_allowed="" av_dmz="" av_note=""
    srvpub="$(av_server_pubkey)"
    av_routes
    echo "# tappaas-admin client config v${AV_CONFIG_VERSION}: mgmt, the site's DNS, the published names"
    echo "[Interface]"
    echo "PrivateKey = ${priv}"
    echo "Address    = ${ip}"
    [[ -n "${av_dns}" ]] && echo "DNS        = ${av_dns}"
    echo "MTU        = 1340"
    echo ""
    echo "[Peer]"
    echo "PublicKey           = ${srvpub}"
    echo "Endpoint            = ${endpoint}"
    [[ -n "${av_note}" ]] && echo "# ${av_note}"
    echo "AllowedIPs          = ${av_allowed}"
    echo "PersistentKeepalive = ${AV_KEEPALIVE}"
}

# The admin peers as JSON lines {name, tunneladdress}.
av_peers() {
    _ow_api /api/wireguard/client/searchClient \
        | jq -c --arg net "${AV_PEER_SUBNET%.*/*}." '.rows[]? | select((.tunneladdress//"")|startswith($net)) | {name, tunneladdress}'
}

# Record that <name> was given a config of this version. Args: <name> <ip/32>
av_record_issued() {
    local f tmp; f="$(av_issued_file)"
    mkdir -p "$(dirname "${f}")" 2>/dev/null || return 0
    tmp="$(mktemp "${f}.XXXXXX")" || return 0
    if { [[ -s "${f}" ]] && cat "${f}" || echo '{}'; } \
        | jq --arg n "$1" --arg ip "$2" --argjson v "${AV_CONFIG_VERSION}" --arg d "$(date -u +%Y-%m-%d)" \
            '.[$n] = {ip: $ip, config: $v, issued: $d}' > "${tmp}" 2>/dev/null; then
        mv "${tmp}" "${f}"
    else
        rm -f "${tmp}"; echo "[Warning] could not record the config issued to ${1} in ${f}" >&2
    fi
}

av_forget_issued() {
    local f tmp; f="$(av_issued_file)"
    [[ -s "${f}" ]] || return 0
    tmp="$(mktemp "${f}.XXXXXX")" || return 0
    jq --arg n "$1" 'del(.[$n])' "${f}" > "${tmp}" 2>/dev/null && mv "${tmp}" "${f}" || rm -f "${tmp}"
}

# `config <name|ip/32> [host:port] [privkey]`: re-print an existing peer's
# config and record it as issued. A name is looked up among the peers; an
# address is taken as given (and recorded when a peer has it).
av_config_cmd() {
    local who="$1" endpoint="${2:-}" priv="${3:-}" ip="" name="" row
    while IFS= read -r row; do
        [[ -n "${row}" ]] || continue
        if [[ "$(jq -r .name <<<"${row}")" == "${who}" || "$(jq -r .tunneladdress <<<"${row}")" == "${who}" ]]; then
            name="$(jq -r .name <<<"${row}")"; ip="$(jq -r .tunneladdress <<<"${row}")"; break
        fi
    done < <(av_peers)
    if [[ -z "${ip}" ]]; then
        [[ "${who}" == */* ]] || { echo "[Error] no admin peer named '${who}' (network-manager wgvpn list)" >&2; return 1; }
        ip="${who}"
    fi
    [[ -n "${endpoint}" ]] || endpoint="$(av_discover_endpoint "$(av_config_dir)" "$(av_server_port)")"
    av_client_config "${ip}" "${endpoint}" "${priv}"
    [[ -z "${name}" ]] || av_record_issued "${name}" "${ip}"
}

# Discover the client-config Endpoint (host:port) when the operator did not pass
# one to `add-peer`. If a satellite carrying the admin-vpn role is registered, use
# its public address — that satellite is what relays :51821 for a CGNAT site.
# Otherwise emit a template placeholder for the operator to fill in (direct /
# Topology-B reach, or before any satellite exists). The port is the admin
# listener's (av_server_port, passed by the callers). A satellite is an instance of the `satellite` module
# (config/<instance>.json, ADR-010 §8.4.1) or, before its conversion, a
# config/satellite-<name>.json. Args: <config-dir> [port]. Echoes host:port.
av_discover_endpoint() {
    local cfgdir="${1:-/home/tappaas/config}" port="${2:-${SAT_ADMIN_WGPORT}}" cfg ip
    for cfg in "${cfgdir}"/*.json; do
        [[ -e "${cfg}" ]] || continue
        if [[ "$(basename "${cfg}")" != satellite-*.json ]]; then
            jq -e '((.moduleSource // .location // "") | split("/") | last) == "satellite"' \
                "${cfg}" >/dev/null 2>&1 || continue
        fi
        # role-gated: only a satellite that actually relays admin-vpn qualifies.
        jq -e '(.roles // []) | index("admin-vpn")' "${cfg}" >/dev/null 2>&1 || continue
        ip="$(jq -r '.address // .host.publicIp // empty' "${cfg}")"
        [[ -n "${ip}" ]] || continue
        printf '%s:%s\n' "${ip}" "${port}"
        return 0
    done
    printf '<satellite-or-cluster-public-ip>:%s\n' "${port}"
}

av_list() {
    local srv issued port wan; srv="$(av_server_uuid)" port="$(av_server_port)"
    echo "server : ${AV_SERVER_NAME} (uuid=${srv:-<none>}) port=${port}"
    [[ -n "${srv}" ]] && echo "pubkey : $(av_server_pubkey "${srv}")"
    echo "rule   : $([[ -n "$(av_rule_uuid)" ]] && echo present || echo MISSING) (${AV_PEER_SUBNET} -> ${AV_MGMT_SUBNET})"
    wan="$(av_wan_rule "${port}")"
    if [[ -n "${wan}" ]]; then
        echo "wan    : present (UDP ${port} -> This Firewall, rule '$(cut -f2- <<<"${wan}")')"
    else
        echo "wan    : MISSING (UDP ${port} -> This Firewall)"
    fi
    echo "peers  :"
    issued="$(jq -c . "$(av_issued_file)" 2>/dev/null)" || issued='{}'
    [[ -n "${issued}" ]] || issued='{}'
    # A peer with no record was enrolled before #856: its tunnel has no DNS line
    # and no route to the published names until it is re-issued and re-imported.
    av_peers | jq -r --argjson i "${issued}" --argjson v "${AV_CONFIG_VERSION}" '
        ($i[.name] // {}) as $r
        | "  - \(.name)  \(.tunneladdress)  "
          + (if ($r.config // 1) >= $v then "config v\($r.config) issued \($r.issued)"
             else "config v\($r.config // 1): no DNS, mgmt only — re-issue (network-manager wgvpn config \(.name)) and re-import" end)'
}
