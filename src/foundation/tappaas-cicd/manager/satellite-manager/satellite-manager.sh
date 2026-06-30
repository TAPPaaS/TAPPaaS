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
# shellcheck source=lib/tunnel.sh
[[ -f "${SCRIPT_DIR}/lib/tunnel.sh" ]] && . "${SCRIPT_DIR}/lib/tunnel.sh"

usage() {
    cat << EOF
${SCRIPT_NAME} ${VERSION} — TAPPaaS VPS satellite manager (ADR-010)

Usage:
  ${SCRIPT_NAME} install  <name>     Provision + wire a satellite
  ${SCRIPT_NAME} update   <name>     Pull-based config update
  ${SCRIPT_NAME} status   <name>     Tunnel / role / backup health
  ${SCRIPT_NAME} remove   <name>     Decommission (tunnel/zone/DNS/secrets)
  ${SCRIPT_NAME} validate <name>     Validate satellite-<name>.json
  ${SCRIPT_NAME} --help              This help

Config: \${CONFIG_DIR}/satellite-<name>.json  (currently: ${CONFIG_DIR})
Docs:   src/foundation/satellite/INSTALL.md
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

not_implemented() {
    local verb="$1" name="$2" pkg="$3"
    warn "satellite ${verb} '${name}' is not implemented yet (lands in ${pkg})."
    info "Planned: $4"
    exit 2
}

main() {
    local verb="${1:-}"; shift || true
    case "${verb}" in
        install)
            local name="${1:?usage: ${SCRIPT_NAME} install <name>}"
            require_config "${name}" >/dev/null
            not_implemented install "${name}" "P2-P6" \
                "nixos-anywhere deploy; WireGuard listener (home dials out); read back pubkey; add edge/admin zones + role-gated fw + reconcile; dns-manager; revoke provisioning cred; per-role (nginx-stream / admin UDP relay / PBS pull + S3 Object-Lock)."
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
            local name="${1:?usage: ${SCRIPT_NAME} remove <name>}"
            require_config "${name}" >/dev/null
            not_implemented remove "${name}" "P3" \
                "tear down os-wireguard peer; remove edge/admin zones + reconcile; revert DNS; forget secrets; fall back to prior reachability."
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
