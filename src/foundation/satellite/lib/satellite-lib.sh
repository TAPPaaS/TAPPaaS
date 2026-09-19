#!/usr/bin/env bash
# lib/satellite-lib.sh — what the satellite module's lifecycle scripts share
# (ADR-010 §8.4). The satellite is a `kind: machine` module: module-manager adds,
# updates, tests and deletes it through install.sh / update.sh / test.sh /
# delete.sh, which are thin wrappers over the functions here.
#
# Sourced after common-install-routines.sh (info/warn/error/die, colours).
# sat_load sets: INSTANCE SAT_CFG SAT_NAME ADDRESS SAT_USER SAT_ROLES SAT_OS SAT_MGMT
#
# shellcheck shell=bash

SAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SATELLITE_SRC="${SATELLITE_SRC:-$(cd "${SAT_LIB_DIR}/.." && pwd)}"
# shellcheck source=provision.sh
. "${SAT_LIB_DIR}/provision.sh"
# shellcheck source=tunnel.sh
. "${SAT_LIB_DIR}/tunnel.sh"
# shellcheck source=../../tappaas-cicd/lib/opnsense-wg.sh
. "${SATELLITE_SRC}/../tappaas-cicd/lib/opnsense-wg.sh"

# The mothership's own key: authorized on a managed satellite, removed by lockdown.
SAT_CICD_PUB="${SAT_CICD_PUB:-${HOME}/.ssh/id_ed25519.pub}"
# Roles a satellite takes at `module add`; `backup` is set by --lockdown (§8.4.4).
SAT_ADD_ROLES="reverse-proxy admin-vpn"

# sat_load <instance> — load config/<instance>.json. A satellite from before
# ADR-010 §8.4 is config/satellite-<name>.json; naming it by <name> still works
# for one release.
sat_load() {
    INSTANCE="${1:?usage: <instance>}"
    local dir="${CONFIG_DIR:-/home/tappaas/config}"
    SAT_CFG="${dir}/${INSTANCE}.json"
    if [[ ! -f "${SAT_CFG}" && -f "${dir}/satellite-${INSTANCE}.json" ]]; then
        SAT_CFG="${dir}/satellite-${INSTANCE}.json"
        INSTANCE="satellite-${INSTANCE}"
    fi
    [[ -f "${SAT_CFG}" ]] || die "no config for '${INSTANCE}' (${SAT_CFG}) — add one: module-manager module add satellite --address <public-ip>"
    jq empty "${SAT_CFG}" 2>/dev/null || die "${SAT_CFG} is not valid JSON"
    # The name the OPNsense side knows it by (tappaas-<name>, tappaas-edge-<name>).
    SAT_NAME="$(jq -r '.name // empty' "${SAT_CFG}")"
    [[ -n "${SAT_NAME}" ]] || SAT_NAME="${INSTANCE}"
    # Its public address: how the tunnel, the relay and a managed login reach it.
    ADDRESS="$(jq -r '.address // .host.publicIp // empty' "${SAT_CFG}")"
    SAT_USER="$(jq -r '.host.sshUser // "root"' "${SAT_CFG}")"
    SAT_ROLES="$(jq -r '(.roles // []) | join(",")' "${SAT_CFG}")"
    SAT_OS="$(jq -r '.os // "debian"' "${SAT_CFG}")"
    SAT_MGMT="$(jq -r '.management // "managed"' "${SAT_CFG}")"
    return 0
}

# sat_has_role <role>
sat_has_role() { [[ ",${SAT_ROLES}," == *",$1,"* ]]; }

# sat_set <jq-filter> [jq args...] — rewrite the instance's config in place,
# keeping its mode and owner (#525).
sat_set() {
    local filter="$1"; shift
    local tmp="${SAT_CFG}.sat.tmp"
    cp -p "${SAT_CFG}" "${tmp}" || die "cannot stage ${SAT_CFG}"
    if jq "$@" "${filter}" "${SAT_CFG}" > "${tmp}" && jq empty "${tmp}" 2>/dev/null; then
        mv -f "${tmp}" "${SAT_CFG}"
    else
        rm -f "${tmp}"; die "could not update ${SAT_CFG}"
    fi
}

# sat_ssh <command...> — root on the satellite by the mothership's key only (no
# agent), as the sweep reaches a managed machine. The one way update/test log in.
sat_ssh() {
    SSH_AUTH_SOCK='' ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes -i "${SAT_CICD_PUB%.pub}" -o LogLevel=ERROR \
        "${SAT_USER}@${ADDRESS}" "$@"
}

# sat_operator_keys — the operator's out-of-band public keys, one per line: the
# config's host.operatorSshKeys, else TAPPAAS_OPERATOR_KEY (a key or a file),
# else what the forwarded agent holds (`module add` runs over `ssh -A`). Never
# the mothership's own key: that one is for managing, and lockdown removes it.
sat_operator_keys() {
    local keys cicd=""
    keys="$(jq -r '(.host.operatorSshKeys // [])[]' "${SAT_CFG}")"
    if [[ -z "${keys}" && -n "${TAPPAAS_OPERATOR_KEY:-}" ]]; then
        if [[ -f "${TAPPAAS_OPERATOR_KEY}" ]]; then keys="$(cat "${TAPPAAS_OPERATOR_KEY}")"; else keys="${TAPPAAS_OPERATOR_KEY}"; fi
    fi
    [[ -n "${keys}" ]] || keys="$(ssh-add -L 2>/dev/null | grep -E '^(ssh-|ecdsa-|sk-)' || true)"
    [[ -f "${SAT_CICD_PUB}" ]] && cicd="$(awk '{print $2}' "${SAT_CICD_PUB}")"
    awk -v c="${cicd}" 'NF>=2 && (c == "" || $2 != c)' <<< "${keys}"
}

# sat_check_roles — the roles a satellite can be added with.
sat_check_roles() {
    [[ -n "${SAT_ROLES}" ]] || die "${INSTANCE}: no roles — give them at add: --roles '[\"reverse-proxy\",\"admin-vpn\"]'"
    local r
    for r in ${SAT_ROLES//,/ }; do
        if [[ "${r}" == backup ]]; then
            [[ "${SAT_MGMT}" == unmanaged ]] && continue
            die "${INSTANCE}: the backup role is set by locking the satellite down as a pull vault — add it without, then: module-manager module modify ${INSTANCE} --lockdown (ADR-010 §8.4.4)"
        fi
        [[ " ${SAT_ADD_ROLES} " == *" ${r} "* ]] || die "${INSTANCE}: unknown role '${r}' (reverse-proxy, admin-vpn)"
    done
}

# sat_edge_rules_ensure — the OPNsense edge rules the roles need (idempotent).
sat_edge_rules_ensure() {
    if sat_has_role reverse-proxy || sat_has_role admin-vpn; then
        sat_ensure_edge_rules "${SAT_ROLES}" >/dev/null || return 1
    fi
    return 0
}

# sat_opnsense_uuid <client|server> — the tunnel's OPNsense object, by name.
sat_opnsense_uuid() {
    local path name
    case "$1" in
        client) path=/api/wireguard/client/searchClient; name="tappaas-${SAT_NAME}" ;;
        server) path=/api/wireguard/server/searchServer; name="tappaas-edge-${SAT_NAME}" ;;
        *) return 1 ;;
    esac
    _ow_api "${path}" | jq -r --arg n "${name}" '.rows[]? | select(.name==$n) | .uuid' | head -1
}

# sat_install — provision the machine and wire the home side (ADR-010 §5, §8.4.1).
sat_install() {
    [[ -n "${ADDRESS}" ]] || die "${INSTANCE}: no address — give the satellite's public IPv4: module-manager module add satellite --address <public-ip>"
    [[ "${SAT_OS}" == debian || "${SAT_OS}" == nixos ]] || die "${INSTANCE}: os must be debian (default) or nixos, not '${SAT_OS}'"
    sat_check_roles
    command -v jq >/dev/null || die "jq required"

    local keys; keys="$(sat_operator_keys)"
    [[ -n "${keys}" ]] || die "no operator key — run 'module add' over 'ssh -A' so your workstation's key is forwarded, or set TAPPAAS_OPERATOR_KEY (a public key or a file)"
    if ! jq -e '(.host.operatorSshKeys // []) | length > 0' "${SAT_CFG}" >/dev/null; then
        sat_set '.host = ((.host // {}) + {operatorSshKeys: ($k | split("\n") | map(select(length > 0)))})' --arg k "${keys}"
        info "  recorded $(wc -l <<< "${keys}" | tr -d ' ') operator key(s) — your out-of-band access"
    fi

    local sname="tappaas-edge-${SAT_NAME}" cname="tappaas-${SAT_NAME}" target="${SAT_USER}@${ADDRESS}"
    if [[ -n "$(sat_opnsense_uuid server)" ]]; then
        die "OPNsense already has ${sname} — this satellite is wired. To provision it again: module-manager module delete ${INSTANCE} --decommission, then add it"
    fi

    info "${BOLD}Satellite ${BL}${INSTANCE}${CL}${BOLD}: ${ADDRESS}, os ${SAT_OS}, roles ${SAT_ROLES}, ${SAT_MGMT}${CL}"
    if [[ "${SAT_OS}" == nixos ]]; then
        # The NixOS option reformats the host and patches itself (autoUpgrade);
        # it holds no mothership key, so it is recorded unmanaged.
        command -v nix >/dev/null || die "nix required for os nixos"
        [[ -f "${PROVISION_KEY}" ]] || { warn "generating provisioning key ${PROVISION_KEY}"; ssh-keygen -t ed25519 -f "${PROVISION_KEY}" -N "" -q; }
        ssh -i "${PROVISION_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "${target}" true 2>/dev/null \
            || die "cannot log in to ${target} with the provisioning key — add it to root's authorized_keys first: $(cat "${PROVISION_KEY}.pub")"
    else
        # Debian: the operator's key (forwarded agent) reaches the stock host.
        ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes "${target}" true 2>/dev/null \
            || die "cannot log in to ${target} — run 'module add' over 'ssh -A' so your operator key reaches it"
        [[ "${SAT_MGMT}" != managed || -f "${SAT_CICD_PUB}" ]] || die "no ${SAT_CICD_PUB} — a managed satellite authorizes the mothership's key"
    fi

    info "  [1/6] OPNsense home WG server ${sname}"
    local kp home_priv home_pub srv
    kp="$(ow_genkey)"; home_priv="${kp% *}"; home_pub="${kp#* }"
    srv="$(ow_add_server "${sname}" "${SAT_HOME_ADDR}/31" "${home_priv}" "${home_pub}")"
    [[ -n "${srv}" ]] || die "OPNsense addServer failed"

    if [[ "${SAT_OS}" == debian ]]; then
        info "  [2/6] render Debian configs"
        local cdir cicd_key=""; cdir="$(mktemp -d)"
        [[ "${SAT_MGMT}" == managed ]] && cicd_key="${SAT_CICD_PUB}"
        sat_gen_debian_configs "${SAT_CFG}" "${home_pub}" "${cdir}" "${cicd_key}" \
            || die "Debian config generation failed"
        info "  [3/6] provision Debian on ${target}"
        sat_provision_debian "$(sat_assemble_debian_deploy "${cdir}")" "${target}" || die "Debian provisioning failed"
    else
        info "  [2/6] generate satellite-settings.nix"
        local settings; settings="$(mktemp)"
        sat_gen_settings "${SAT_CFG}" "${home_pub}" "${settings}" || die "settings generation failed"
        info "  [3/6] nixos-anywhere -> ${target} (reformats to NixOS)"
        sat_nixos_anywhere "$(sat_assemble_deploy "${settings}")" "${target}" || die "nixos-anywhere failed"
        sat_set '.management = "unmanaged"'
        SAT_MGMT=unmanaged
    fi

    info "  [4/6] read back the satellite's tunnel key"
    local sat_pub
    sat_pub="$(sat_read_pubkey "${target}")" || die "could not read the satellite's public key — run 'module add' over 'ssh -A'"

    info "  [5/6] OPNsense peer ${cname}"
    local cli
    cli="$(ow_add_client "${cname}" "${sat_pub}" "${ADDRESS}" "${SAT_WGPORT}" "${SAT_KEEPALIVE}" "${SAT_SAT_ADDR}/32" "${srv}")"
    [[ -n "${cli}" ]] || die "OPNsense addClient failed"
    ow_link_server_peer "${srv}" "${sname}" "${SAT_HOME_ADDR}/31" "${home_priv}" "${home_pub}" "${cli}" >/dev/null
    ow_enable_and_apply >/dev/null

    info "  [6/6] OPNsense edge rules for ${SAT_ROLES}"
    sat_edge_rules_ensure || warn "  edge rule setup reported an issue"
    sleep 12
    info "  peer: $(ow_peer_status)"

    if [[ "${SAT_MGMT}" == managed ]]; then
        sat_ssh true || die "the mothership's key does not reach ${target} — it should have been authorized by provisioning"
        info "  ${GN}✓${CL} managed: the mothership reaches ${ADDRESS}; the sweep patches it"
    fi
    info "${GN}✓${CL} satellite ${INSTANCE} provisioned"
}

# sat_decommission — take the Site's side of the satellite down (ADR-010 §8.4.5):
# the OPNsense peer and tunnel server, and the edge rules when no other satellite
# needs them. The machine itself is never touched.
sat_decommission() {
    local cli srv
    cli="$(sat_opnsense_uuid client)"; srv="$(sat_opnsense_uuid server)"
    [[ -n "${cli}" ]] && { ow_del_client "${cli}"; info "  removed OPNsense peer tappaas-${SAT_NAME}"; }
    [[ -n "${srv}" ]] && { ow_del_server "${srv}"; info "  removed OPNsense server tappaas-edge-${SAT_NAME}"; }
    [[ -n "${cli}${srv}" ]] || info "  no OPNsense tunnel objects for ${SAT_NAME} — nothing to remove there"
    if [[ -z "$(sat_other_satellites)" ]]; then
        local d uuid
        for d in "tappaas-satellite edge->caddy 80" "tappaas-satellite edge->caddy 443" \
                 "tappaas-satellite edge->admin-wg" "tappaas-satellite edge->home-pbs"; do
            uuid="$(_ow_api /api/firewall/filter/searchRule | jq -r --arg d "${d}" '.rows[]? | select(.description==$d) | .uuid' | head -1)"
            [[ -n "${uuid}" ]] && { _ow_api -X POST "/api/firewall/filter/delRule/${uuid}" >/dev/null; info "  removed rule '${d}'"; }
        done
        _ow_api -X POST /api/firewall/filter/apply >/dev/null
    else
        info "  edge rules kept — still used by: $(sat_other_satellites | tr '\n' ' ')"
    fi
    ow_enable_and_apply >/dev/null
    warn "  the machine at ${ADDRESS:-?} is untouched — destroying it is yours to do in the provider's console"
    info "${GN}✓${CL} ${INSTANCE}: the Site's side is taken down"
}

# sat_other_satellites — the other satellite instances in config/, one per line.
sat_other_satellites() {
    local dir="${CONFIG_DIR:-/home/tappaas/config}" f
    for f in "${dir}"/*.json; do
        [[ -f "${f}" && "${f}" != "${SAT_CFG}" ]] || continue
        if [[ "$(basename "${f}")" == satellite-*.json ]] \
           || jq -e '((.moduleSource // .location // "") | split("/") | last) == "satellite"' "${f}" >/dev/null 2>&1; then
            basename "${f}" .json
        fi
    done
}
