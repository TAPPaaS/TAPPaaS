#!/usr/bin/env bash
#
# wgvpn.sh — the admin VPN (`network-manager wgvpn …`, ADR-010 §6, §8.4.6).
#
# The operator's WireGuard session into the management plane terminates on
# OPNsense and needs no satellite: a Site with a public IP is reached directly, a
# CGNAT Site through a satellite that relays the UDP. network-manager owns it
# because OPNsense does; `network-manager wgvpn <sub>` runs this script, which
# network-manager's install.sh links as ~/bin/network-manager-wgvpn.
# (Formerly `satellite-manager admin`.) Runbook: ../ADMIN-VPN.md.
#
set -euo pipefail

_src="${BASH_SOURCE[0]}"
if readlink -f "${_src}" >/dev/null 2>&1; then _src="$(readlink -f "${_src}")"; fi
HERE="$(cd "$(dirname "${_src}")" && pwd)"
# shellcheck source=wgvpn-lib.sh
. "${HERE}/wgvpn-lib.sh"
# shellcheck source=../../../lib/cli-gate.sh
. "${HERE}/../../../lib/cli-gate.sh"

CLI="network-manager wgvpn"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"
YW=$'\033[01;33m'; RD=$'\033[01;31m'; CL=$'\033[0m'
info()  { echo "${*}" >&2; }
warn()  { echo "${YW}[Warning]${CL} ${*}" >&2; }
die()   { echo "${RD}[Error]${CL} ${*}" >&2; exit 1; }

# What each sub-verb accepts (lib/cli-gate.sh; '=' marks an option with a value).
readonly CLI_SPEC='
setup:
list:
status:
add-peer: --name= --pubkey= --ip= --endpoint=
remove-peer:
config:
'

usage() {
    cat <<EOF
Usage: ${CLI} <sub>
  setup                                            ensure the OPNsense admin-WG server, the admin->mgmt rule
                                                   and the WAN :${SAT_ADMIN_WGPORT} rule (idempotent)
  add-peer --name N --pubkey K [--ip A] [--endpoint H:P]
                                                   register an admin device (auto-assigns an admin IP) and
                                                   print its client config. Endpoint: --endpoint wins, else a
                                                   registered admin-vpn satellite's address, else a placeholder
  remove-peer <name>                               remove an admin device
  list                                             show server pubkey, rule status, peers
  config <ip/32> <host:port> [privkey]             re-print a client config for an existing peer

The tunnel terminates on OPNsense, so it works with no satellite (a Site with a
public IP) or through one (a CGNAT Site). Runbook: network-manager/ADMIN-VPN.md.
EOF
}

main() {
    [[ $# -gt 0 ]] && cli_gate usage "${CLI_SPEC}" "$@"
    local sub="${1:-}"; shift || true
    case "${sub}" in
        setup)   av_setup ;;
        list|status) av_list ;;
        add-peer)
            local name="" pub="" ip="" endpoint=""
            while [[ $# -gt 0 ]]; do case "$1" in
                --name) name="$2"; shift 2 ;;
                --pubkey) pub="$2"; shift 2 ;;
                --ip) ip="$2"; shift 2 ;;
                --endpoint) endpoint="$2"; shift 2 ;;
                *) die "add-peer: unknown option $1" ;;
            esac; done
            [[ -n "${name}" && -n "${pub}" ]] || die "add-peer needs --name and --pubkey"
            local got; got="$(av_add_peer "${name}" "${pub}" "${ip}")"
            av_apply >/dev/null
            info "peer '${name}' added at ${got}"
            # A peer is only useful with a client config, so emit it right here.
            # The config goes to stdout (info goes to stderr), so it redirects
            # cleanly to a .conf. Endpoint: explicit --endpoint wins; else a
            # registered admin-vpn satellite's address; else a placeholder.
            [[ -n "${endpoint}" ]] || endpoint="$(av_discover_endpoint "${CONFIG_DIR}")"
            info ""
            if [[ "${endpoint}" == *"<"* ]]; then
                info "client config for '${name}' — save as tappaas-admin.conf; fill in Endpoint + paste your private key:"
            else
                info "client config for '${name}' — save as tappaas-admin.conf; paste your private key (Endpoint = ${endpoint}):"
            fi
            av_client_config "${got}" "${endpoint}"
            ;;
        remove-peer)
            local name="${1:-}"; [[ -n "${name}" ]] || die "remove-peer <name>"
            av_remove_peer "${name}"; av_apply >/dev/null
            info "peer '${name}' removed"
            ;;
        config)
            # config <peer-ip/32> <endpoint-host:port> [private-key]
            [[ $# -ge 2 ]] || die "config <peer-ip/32> <endpoint-host:port> [private-key]"
            av_client_config "$1" "$2" "${3:-}"
            ;;
        ""|-h|--help|help) usage ;;
        *) usage; die "unknown sub-verb '${sub}' (setup|add-peer|remove-peer|list|config)" ;;
    esac
}

main "$@"
