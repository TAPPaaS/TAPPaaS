#!/usr/bin/env bash
# lib/pbs-tunnel.sh — the WireGuard tunnel under ONE backup-buddy pull (#796).
#
# One pull = one tunnel, served by the system whose data is pulled (BUDDY.md):
#
#   serving side (remote peer)               dialing side (pull peer)
#   instance buddy-<n>-serve  <net>.1/30     instance buddy-<n>-pull  <net>.2/30
#     peer: puller  AllowedIPs <net>.2/32      peer: server AllowedIPs <net>.1/32
#     WAN   udp/<listenPort> pass              Endpoint <their public ip>:<listenPort>
#     rdr   <net>.2 -> <net>.1:8007            out-NAT  our PBS -> <net>.1 as <net>.2
#           => our PBS :8007                   pass     our PBS -> <net>.1 tcp/8007
#
# AllowedIPs are single addresses and the only thing either side forwards is
# tcp/8007 to one PBS, so the tunnel carries PBS traffic and nothing else: the
# two sites' networks are never routed into each other.
#
# Rules are named "buddy-<n> serve …" / "buddy-<n> pull …"; the zone reconcile
# prunes only its own prefixes, so they survive it. WireGuard objects go through
# tappaas-cicd/lib/opnsense-wg.sh (raw REST, live-validated); filter/NAT rules
# through the opnsense-controller CLIs, like every other TAPPaaS rule.
#
# shellcheck shell=bash
# shellcheck source=/dev/null
_here_bt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${BT_OW_LIB:-${_here_bt}/../../tappaas-cicd/lib/opnsense-wg.sh}"

: "${BT_WG_IFACE:=wireguard}"   # OPNsense WireGuard group interface
: "${BT_WAN_IFACE:=wan}"
: "${BT_MGMT_IFACE:=lan}"       # where our PBS lives (the mgmt zone)
: "${BT_PBS_PORT:=8007}"
: "${BT_KEEPALIVE:=25}"
: "${BT_BIN_DIR:=/home/tappaas/bin}"   # where the controller CLIs are installed

bt_serve_name() { printf 'buddy-%s-serve\n' "$1"; }
bt_pull_name()  { printf 'buddy-%s-pull\n' "$1"; }

# ── /30 arithmetic ───────────────────────────────────────────────────────────
_bt_ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
_bt_int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }

# <a.b.c.d/30> -> "<.1> <.2>" (the two hosts). rc 1 on a malformed or misaligned net.
bt_hosts() {
    local net="$1" ip len n
    [[ "${net}" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})/([0-9]+)$ ]] || { echo "not a CIDR: ${net}" >&2; return 1; }
    ip="${BASH_REMATCH[1]}"; len="${BASH_REMATCH[3]}"
    [[ "${len}" == "30" ]] || { echo "a buddy tunnel is a /30, got /${len}: ${net}" >&2; return 1; }
    n="$(_bt_ip2int "${ip}")"
    (( n % 4 == 0 )) || { echo "${net} is not a /30 boundary" >&2; return 1; }
    echo "$(_bt_int2ip $((n + 1))) $(_bt_int2ip $((n + 2)))"
}

# Our PBS's address — what the tunnel forwards to (serve) or NATs from (dial).
bt_pbs_ip() {
    if [[ -n "${BT_PBS_IP:-}" ]]; then echo "${BT_PBS_IP}"; return 0; fi
    local h; h="$(pbs_pbs_url 2>/dev/null || echo backup.mgmt.internal)"
    h="${h#*://}"; h="${h%%/*}"; h="${h%%:*}"
    if [[ "${h}" =~ ^[0-9.]+$ ]]; then echo "${h}"; return 0; fi
    getent ahostsv4 "${h}" 2>/dev/null | awk 'NR==1{print $1}' | grep . \
        || { echo "cannot resolve the PBS host ${h} (set BT_PBS_IP)" >&2; return 1; }
}

# ── controller CLIs ──────────────────────────────────────────────────────────
_bt_cli() {  # <name> -> path, rc 1 when absent
    local c="${BT_BIN_DIR}/$1"
    [[ -x "${c}" ]] || c="$(command -v "$1" 2>/dev/null || true)"
    [[ -n "${c}" && -x "${c}" ]] || { echo "$1 not found (is opnsense-controller installed?)" >&2; return 1; }
    printf '%s' "${c}"
}
# Pin --port to the REST path's OPNSENSE_PORT: auto-detect latches onto Caddy's :443 (#418).
_bt_run() {  # <cli> <subcommand> <args...>
    local cli; cli="$(_bt_cli "$1")" || return 1; shift
    "${cli}" "$1" --firewall "${OPNSENSE_HOST}" --port "${OPNSENSE_PORT}" --no-ssl-verify "${@:2}"
}
_bt_del() {  # <cli> <description> — absent is fine
    _bt_run "$1" delete-rule --description "$2" >/dev/null 2>&1 || true
}
_bt_fw_apply() { _ow_api -X POST /api/firewall/filter/apply >/dev/null; }

# ── serving side: the system whose data is pulled ───────────────────────────
# Echoes our public key (the dialing side needs it as its peer key). Without a
# peer key the instance is up but admits nobody; re-run with the key to finish.
bt_serve_up() {  # <name> <net/30> <listen-port> <mtu> [peer-pubkey]
    local name="$1" net="$2" port="$3" mtu="$4" peer="${5:-}" hosts us them pbs srv
    hosts="$(bt_hosts "${net}")" || return 1
    us="${hosts% *}"; them="${hosts#* }"
    pbs="$(bt_pbs_ip)" || return 1
    srv="$(ow_ensure_server "$(bt_serve_name "${name}")" "${us}/30" "${port}" "${mtu}")"
    [[ -n "${srv}" ]] || { echo "could not create WireGuard instance $(bt_serve_name "${name}")" >&2; return 1; }
    if [[ -n "${peer}" ]]; then
        ow_ensure_client "$(bt_serve_name "${name}")-peer" "${peer}" "${them}/32" "${srv}" >/dev/null || return 1
    fi
    # Reconfigure first: the wireguard group interface the rules bind to exists only after it.
    ow_enable_and_apply >/dev/null
    _bt_run opnsense-firewall create-rule --description "buddy-${name} serve wg" \
        --interface "${BT_WAN_IFACE}" --action pass --protocol udp --log \
        --source any --destination wanip --destination-port "${port}" >/dev/null || return 1
    _bt_run nat-manager add-rule --description "buddy-${name} serve pbs" \
        --interface "${BT_WG_IFACE}" --protocol tcp --source "${them}/32" --destination "${us}" \
        --external-port "${BT_PBS_PORT}" --target "${pbs}" --internal-port "${BT_PBS_PORT}" >/dev/null || return 1
    ow_server_pubkey_of "${srv}"
}

bt_serve_down() {  # <name>
    local name="$1" srv cli
    _bt_del nat-manager "buddy-${name} serve pbs"
    _bt_del opnsense-firewall "buddy-${name} serve wg"
    cli="$(ow_client_uuid "$(bt_serve_name "${name}")-peer")"
    [[ -z "${cli}" ]] || ow_del_client "${cli}"
    srv="$(ow_server_uuid "$(bt_serve_name "${name}")")"
    [[ -z "${srv}" ]] || ow_del_server "${srv}"
    _ow_api -X POST /api/wireguard/service/reconfigure >/dev/null
    _bt_fw_apply
}

# ── dialing side: the system that pulls ─────────────────────────────────────
# Echoes our public key (the serving side needs it as its peer key).
bt_dial_up() {  # <name> <net/30> <endpoint host:port> <peer-pubkey> <mtu>
    local name="$1" net="$2" ep="$3" peer="$4" mtu="$5" hosts them us pbs srv
    hosts="$(bt_hosts "${net}")" || return 1
    them="${hosts% *}"; us="${hosts#* }"
    [[ "${ep}" == *:* ]] || { echo "endpoint must be host:port, got ${ep}" >&2; return 1; }
    [[ -n "${peer}" ]] || { echo "the serving side's public key is required to dial" >&2; return 1; }
    pbs="$(bt_pbs_ip)" || return 1
    srv="$(ow_ensure_server "$(bt_pull_name "${name}")" "${us}/30" "" "${mtu}")"
    [[ -n "${srv}" ]] || { echo "could not create WireGuard instance $(bt_pull_name "${name}")" >&2; return 1; }
    ow_ensure_client "$(bt_pull_name "${name}")-peer" "${peer}" "${them}/32" "${srv}" \
        "${ep%:*}" "${ep##*:}" "${BT_KEEPALIVE}" >/dev/null || return 1
    ow_enable_and_apply >/dev/null
    # Our PBS reaches <net>.1 as <net>.2 — the only source the far side admits.
    _bt_run snat-manager add-rule --description "buddy-${name} pull nat" \
        --interface "${BT_WG_IFACE}" --source "${pbs}/32" --destination "${them}/32" --target "${us}" >/dev/null || return 1
    _bt_run opnsense-firewall create-rule --description "buddy-${name} pull" \
        --interface "${BT_MGMT_IFACE}" --action pass --protocol tcp --no-log \
        --source "${pbs}" --destination "${them}" --destination-port "${BT_PBS_PORT}" >/dev/null || return 1
    ow_server_pubkey_of "${srv}"
}

bt_dial_down() {  # <name>
    local name="$1" srv cli
    _bt_del opnsense-firewall "buddy-${name} pull"
    _bt_del snat-manager "buddy-${name} pull nat"
    cli="$(ow_client_uuid "$(bt_pull_name "${name}")-peer")"
    [[ -z "${cli}" ]] || ow_del_client "${cli}"
    srv="$(ow_server_uuid "$(bt_pull_name "${name}")")"
    [[ -z "${srv}" ]] || ow_del_server "${srv}"
    _ow_api -X POST /api/wireguard/service/reconfigure >/dev/null
    _bt_fw_apply
}

# ── status ───────────────────────────────────────────────────────────────────
# "<instance> pubkey=<ours> peer=<status hs=age|none>", rc 1 when no instance.
bt_status() {  # <serve|dial> <name>
    local inst cli srv pub peer st
    [[ "$1" == "serve" ]] && inst="$(bt_serve_name "$2")" || inst="$(bt_pull_name "$2")"
    srv="$(ow_server_uuid "${inst}")"
    [[ -n "${srv}" ]] || { echo "${inst} absent"; return 1; }
    pub="$(ow_server_pubkey_of "${srv}")"
    cli="$(ow_client_uuid "${inst}-peer")"
    if [[ -z "${cli}" ]]; then st="none"; else
        peer="$(_ow_api "/api/wireguard/client/getClient/${cli}" | jq -r '.client.pubkey // empty')"
        st="$(ow_peer_status_of "${peer}")"; st="${st:-unknown}"
    fi
    echo "${inst} pubkey=${pub} peer=${st}"
}
