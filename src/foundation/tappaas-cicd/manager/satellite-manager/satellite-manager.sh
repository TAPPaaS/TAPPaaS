#!/usr/bin/env bash
#
# satellite-manager — TAPPaaS VPS satellite front door (ADR-010)
#
# Operator CLI on tappaas-cicd that provisions and manages EXTERNAL satellite
# hosts (a VPS or any machine with a public IP) — reverse-proxy frontend, admin
# VPN, and off-site backup for a cluster with no public IP.
#
# SKELETON (ADR-010 implementation P1): the verb surface is wired; the heavy
# orchestration lands in packages P2-P6 (see docs/design/ADR-010-implementation.md).
# Each verb currently reports what it WILL do and exits "not implemented".
#
# Usage:
#   satellite-manager install  <name>      Provision + wire a satellite (P2-P6)
#   satellite-manager update   <name>      Pull-based config update (P3)
#   satellite-manager status   <name>      Tunnel / role / backup health (P2-P6)
#   satellite-manager remove   <name>      Decommission: tunnel/zone/DNS/secrets (P3)
#   satellite-manager validate <name>      Validate satellite-<name>.json (P1)
#
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly VERSION="0.1.0"

# Real implementation sources the cluster toolbox; the skeleton stays standalone
# so fast tests run anywhere. (P3: `. /home/tappaas/bin/common-install-routines.sh`)
YW=$'\033[01;33m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'; CL=$'\033[0m'
info() { echo "${*}"; }
warn() { echo "${YW}[Warning]${CL} ${*}" >&2; }
error() { echo "${RD}[Error]${CL} ${*}" >&2; }
die() { error "${*}"; exit 1; }

CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"

# Resolve our real dir even when invoked via the ~/bin symlink, so lib/ is found.
_src="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1 && readlink -f "${_src}" >/dev/null 2>&1; then
    _src="$(readlink -f "${_src}")"
fi
SCRIPT_DIR="$(cd "$(dirname "${_src}")" && pwd)"
for _lib in tunnel opnsense-wg provision; do
    # shellcheck source=/dev/null
    [[ -f "${SCRIPT_DIR}/lib/${_lib}.sh" ]] && . "${SCRIPT_DIR}/lib/${_lib}.sh"
done
DRY_RUN=0

usage() {
    cat << EOF
${SCRIPT_NAME} ${VERSION} — TAPPaaS VPS satellite manager (ADR-010)

Usage:
  ${SCRIPT_NAME} install  <name> [--dry-run]   Provision + wire a satellite
  ${SCRIPT_NAME} update   <name>               Pull-based config update
  ${SCRIPT_NAME} status   <name>               Tunnel / role / backup health
  ${SCRIPT_NAME} remove   <name> [--dry-run]   Decommission (tunnel side)
  ${SCRIPT_NAME} validate <name>               Validate satellite-<name>.json
  ${SCRIPT_NAME} --help                        This help

Run install over an agent-forwarded session ('ssh -A') so your OPERATOR key is
available for the post-provision pubkey read-back (§7.3: cicd holds no standing
key on the satellite). Config: \${CONFIG_DIR}/satellite-<name>.json (now: ${CONFIG_DIR})
Docs: src/foundation/satellite/INSTALL.md
EOF
}

# Resolve the config path for a satellite name (no read yet — P1 validate does that).
config_path() {
    local name="${1:?satellite name required}"
    echo "${CONFIG_DIR}/satellite-${name}.json"
}

require_config() {
    local cfg; cfg="$(config_path "$1")"
    [[ -f "${cfg}" ]] || die "config not found: ${cfg} (copy src/foundation/satellite/satellite.json — see INSTALL.md)"
    command -v jq >/dev/null 2>&1 || die "jq is required"
    jq empty "${cfg}" 2>/dev/null || die "invalid JSON: ${cfg}"
    echo "${cfg}"
}

cmd_validate() {
    local cfg; cfg="$(require_config "$1")"
    # P1: structural checks against schemas/satellite-fields.json.
    local roles; roles="$(jq -r '.roles // [] | join(",")' "${cfg}")"
    local ip; ip="$(jq -r '.host.publicIp // empty' "${cfg}")"
    [[ -n "${ip}" ]] || die "host.publicIp is required"
    [[ -n "${roles}" ]] || die "at least one role is required (reverse-proxy|admin-vpn|backup)"
    info "${GN}✓${CL} ${cfg} — roles: ${roles}, publicIp: ${ip}"
    # TODO[P1]: full field validation + cross-field rules (e.g. backup.s3.objectLock
    #           required when backend=s3; adminWgPort != wgPort).
}

cmd_status() {
    local cfg; cfg="$(require_config "$1")"
    local ip user roles
    ip="$(jq -r '.host.publicIp // empty' "${cfg}")"
    user="$(jq -r '.host.sshUser // "root"' "${cfg}")"
    roles="$(jq -r '.roles // [] | join(", ")' "${cfg}")"
    local target="${user}@${ip}"
    info "satellite '${1}' — roles: ${roles:-none}"
    info "  host: ${target}"

    if ! declare -F tunnel_handshake_age >/dev/null; then
        die "lib/tunnel.sh not loaded (satellite-manager install corrupt?)"
    fi
    local age rc=0
    age="$(tunnel_handshake_age "${target}")" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        warn "  wg-infra: ${age} — satellite unreachable or tunnel not up."
        warn "  (a satellite is provisioned by 'satellite-manager install' — P3; until then this is expected.)"
        return 1
    fi
    case "${age}" in
        never)  info "  wg-infra: up, no handshake yet" ;;
        *)      info "  wg-infra: last handshake ${age}s ago" ;;
    esac
    # TODO[P4-P6]: per-role health — reverse-proxy (nginx :443/:80), admin-vpn
    #             (UDP relay), backup (PBS pull sync convergence).
    return 0
}

cmd_install() {
    local name="$1"
    local cfg; cfg="$(require_config "${name}")"
    local ip user wgport ka sat_addr home_addr roles sname cname target
    ip="$(jq -r '.host.publicIp' "${cfg}")"
    user="$(jq -r '.host.sshUser // "root"' "${cfg}")"
    wgport="$(jq -r '.tunnel.wgPort // 51820' "${cfg}")"
    ka="$(jq -r '.tunnel.persistentKeepalive // 25' "${cfg}")"
    sat_addr="$(jq -r '.tunnel.satelliteAddr // "10.255.0.0"' "${cfg}")"
    home_addr="$(jq -r '.tunnel.homeAddr // "10.255.0.1"' "${cfg}")"
    roles="$(jq -r '.roles // [] | join(",")' "${cfg}")"
    sname="tappaas-edge-${name}"; cname="tappaas-${name}"
    target="${user}@${ip}"

    info "satellite install '${name}' — ip=${ip} roles=${roles:-none} wgPort=${wgport}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "  [dry-run] would:"
        info "   1. OPNsense: create WG server '${sname}' (home ${home_addr}/31); read home pubkey"
        info "   2. generate satellite-settings.nix (roles=[${roles}] + home pubkey + operator keys)"
        info "   3. nixos-anywhere --flake .#satellite --target-host ${target} -i ${PROVISION_KEY}"
        info "   4. read back the satellite wg pubkey (operator key via ssh-agent)"
        info "   5. OPNsense: create peer '${cname}' (serveraddress=${ip}:${wgport}, keepalive=${ka}); link; reconfigure"
        info "   6. verify handshake"
        return 0
    fi

    command -v nix >/dev/null || die "nix required — run satellite-manager install on tappaas-cicd"
    command -v jq >/dev/null || die "jq required"
    [[ -f "${PROVISION_KEY}" ]] || { warn "generating provisioning key ${PROVISION_KEY}"; ssh-keygen -t ed25519 -f "${PROVISION_KEY}" -N "" -q; }
    if ! ssh -i "${PROVISION_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "${target}" true 2>/dev/null; then
        error "cicd cannot SSH to ${target} with the provisioning key. Add this key to the"
        error "satellite's root authorized_keys (operator, out-of-band), then re-run:"
        error "  $(cat "${PROVISION_KEY}.pub")"
        exit 1
    fi

    info "  [1/6] OPNsense home WG server ${sname}"
    local kp home_priv home_pub srv
    kp="$(ow_genkey)"; home_priv="${kp% *}"; home_pub="${kp#* }"
    srv="$(ow_add_server "${sname}" "${home_addr}/31" "${home_priv}" "${home_pub}")"
    [[ -n "${srv}" ]] || die "OPNsense addServer failed"
    info "    server=${srv} home_pub=${home_pub}"

    info "  [2/6] generate satellite-settings.nix"
    local settings; settings="$(mktemp)"
    sat_gen_settings "${cfg}" "${home_pub}" "${settings}" || die "settings generation failed"

    info "  [3/6] nixos-anywhere -> ${target} (reformats to NixOS)"
    local d; d="$(sat_assemble_deploy "${settings}")"
    sat_nixos_anywhere "${d}" "${target}" || die "nixos-anywhere failed"

    info "  [4/6] read back satellite wg pubkey (operator key via ssh-agent)"
    local sat_pub
    sat_pub="$(sat_read_pubkey "${target}")" \
        || die "could not read satellite pubkey — run install over 'ssh -A' so your operator key reaches ${target}"
    info "    satellite pubkey=${sat_pub}"

    info "  [5/6] OPNsense peer ${cname}"
    local cli
    cli="$(ow_add_client "${cname}" "${sat_pub}" "${ip}" "${wgport}" "${ka}" "${sat_addr}/32" "${srv}")"
    [[ -n "${cli}" ]] || die "OPNsense addClient failed"
    ow_link_server_peer "${srv}" "${sname}" "${home_addr}/31" "${home_priv}" "${home_pub}" "${cli}" >/dev/null
    ow_enable_and_apply >/dev/null

    info "  [6/6] verify handshake"
    sleep 12
    info "    peer: $(ow_peer_status)"
    info "${GN}✓${CL} satellite '${name}' provisioned. (DNS + role bodies: P4-P6.)"
}

cmd_remove() {
    local name="$1"
    local cfg; cfg="$(require_config "${name}")"
    info "satellite remove '${name}' — tearing down the OPNsense tunnel side"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "  [dry-run] would delete OPNsense peer/server tappaas-{,edge-}${name}, reconfigure,"
        info "            revert DNS, and forget secrets. VPS destruction stays manual (§5.6)."
        return 0
    fi
    # find + delete the peer then the server by name
    local B; B="https://${OPNSENSE_HOST:-firewall.mgmt.internal}:${OPNSENSE_PORT:-8443}"
    local cli srv
    cli="$(_ow_api /api/wireguard/client/searchClient | jq -r --arg n "tappaas-${name}" '.rows[]? | select(.name==$n) | .uuid' | head -1)"
    srv="$(_ow_api /api/wireguard/server/searchServer | jq -r --arg n "tappaas-edge-${name}" '.rows[]? | select(.name==$n) | .uuid' | head -1)"
    [[ -n "${cli}" ]] && { ow_del_client "${cli}"; info "  deleted peer ${cli}"; }
    [[ -n "${srv}" ]] && { ow_del_server "${srv}"; info "  deleted server ${srv}"; }
    ow_enable_and_apply >/dev/null
    warn "  destroying the VPS itself is manual (your cloud account) unless the Tier-B API token is set (§5.6)."
    info "${GN}✓${CL} satellite '${name}' tunnel torn down."
}

not_implemented() {
    local verb="$1" name="$2" pkg="$3"
    warn "satellite ${verb} '${name}' is not implemented yet (lands in ${pkg})."
    info "Planned: $4"
    exit 2
}

main() {
    # filter --dry-run out of the args (order-independent)
    local args=()
    local a
    for a in "$@"; do
        case "${a}" in
            --dry-run) DRY_RUN=1 ;;
            *) args+=("${a}") ;;
        esac
    done
    set -- "${args[@]}"

    local verb="${1:-}"; shift || true
    case "${verb}" in
        install)
            cmd_install "${1:?usage: ${SCRIPT_NAME} install <name> [--dry-run]}"
            ;;
        update)
            local name="${1:?usage: ${SCRIPT_NAME} update <name>}"
            require_config "${name}" >/dev/null
            not_implemented update "${name}" "P3" \
                "pull-based autoUpgrade from the pinned/signed ref (cluster never pushes)."
            ;;
        status)
            cmd_status "${1:?usage: ${SCRIPT_NAME} status <name>}"
            ;;
        remove)
            cmd_remove "${1:?usage: ${SCRIPT_NAME} remove <name> [--dry-run]}"
            ;;
        validate)
            cmd_validate "${1:?usage: ${SCRIPT_NAME} validate <name>}"
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            usage
            die "unknown verb: ${verb}"
            ;;
    esac
}

main "$@"
