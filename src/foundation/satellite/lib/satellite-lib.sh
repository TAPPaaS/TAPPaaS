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
# the OPNsense peer and tunnel server, a vault's read access to the Site's PBS,
# and the edge rules when no other satellite needs them. The machine itself — and
# any copy a vault holds — is never touched.
sat_decommission() {
    local cli srv
    cli="$(sat_opnsense_uuid client)"; srv="$(sat_opnsense_uuid server)"
    [[ -n "${cli}" ]] && { ow_del_client "${cli}"; info "  removed OPNsense peer tappaas-${SAT_NAME}"; }
    [[ -n "${srv}" ]] && { ow_del_server "${srv}"; info "  removed OPNsense server tappaas-edge-${SAT_NAME}"; }
    [[ -n "${cli}${srv}" ]] || info "  no OPNsense tunnel objects for ${SAT_NAME} — nothing to remove there"
    # A vault's read access to the Site's PBS (the `remote` peer lockdown added).
    if [[ -f "${CONFIG_DIR:-/home/tappaas/config}/remote-${SAT_NAME}.json" ]]; then
        if backup-manager peer delete remote "${SAT_NAME}"; then
            info "  revoked ${SAT_NAME}'s read access to the Site's PBS"
        else
            warn "  could not revoke ${SAT_NAME}'s read access to the Site's PBS — run: backup-manager peer delete remote ${SAT_NAME}"
        fi
    fi
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

# sat_home_pbs_address — the address of the Site's PBS, as the vault reaches it
# through the tunnel: vault.pull.homePbsHost when recorded, else the PBS's own
# DNS name (backup's instance name in its zone, ADR-012 §2.7) resolved here — the
# satellite resolves no home names, and its tunnel admits addresses only.
sat_home_pbs_address() {
    local dir="${CONFIG_DIR:-/home/tappaas/config}" h zone
    h="$(jq -r '(.vault // .backup // {}).pull.homePbsHost // empty' "${SAT_CFG}")"
    if [[ -z "${h}" ]]; then
        zone="$(jq -r '.zone0 // "mgmt"' "${dir}/backup.json" 2>/dev/null)"
        h="backup.${zone:-mgmt}.internal"
    fi
    if [[ "${h}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then printf '%s' "${h}"; return 0; fi
    getent ahostsv4 "${h}" 2>/dev/null | awk 'NR==1 {print $1}'
}

# sat_pbs_fingerprint <address> — the SHA-256 fingerprint of the PBS's TLS
# certificate, as the PBS itself reports it, read over the mothership's root key
# on its Host (as the `remote` peer's onboarding does): the vault pins it.
sat_pbs_fingerprint() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        "root@$1" 'proxmox-backup-manager cert info' 2>/dev/null \
        | sed -n 's/^Fingerprint (sha256): //p' | head -1
}

# sat_lockdown — make a managed satellite the Site's off-site vault (ADR-010
# §8.4.4). Everything is done over the mothership's key, and removing that key is
# the last thing that happens: until then a failure leaves a managed satellite
# that can be fixed and locked down again.
#   home: a read-only login on the Site's PBS, granted like any `remote` peer
#         (DatastoreReader, one namespace, not propagated — ADR-012 §1.4)
#   OPNsense: edge -> the PBS :8007
#   satellite: the backup role (PBS, datastore, pull, prune), unattended
#         security upgrades, and — last — the mothership's key removed
# Recorded after: roles + backup, vault.pull, management: unmanaged.
sat_lockdown() {
    local dir="${CONFIG_DIR:-/home/tappaas/config}" bj
    bj="${dir}/backup.json"
    [[ "${SAT_MGMT}" == managed ]] || die "${INSTANCE} is already locked down (management: ${SAT_MGMT})"
    [[ "${SAT_OS}" == debian ]] || die "${INSTANCE} runs ${SAT_OS}: the vault is the Debian satellite's (official PBS, ADR-010 D19)"
    [[ -n "${ADDRESS}" ]] || die "${INSTANCE} records no address"
    [[ -f "${bj}" ]] || die "no config/backup.json — there is no Site PBS for the vault to pull"
    [[ "$(jq -r '.node // empty' "${bj}")" != "${INSTANCE}" ]] \
        || die "${INSTANCE} is the Site's PBS Host (backup.json node) — the Site's only copy cannot also be its protected copy (ADR-010 §8.4.4)"
    case "$(jq -r '.placementState // empty' "${bj}")" in
        node|node:*|local) ;;
        *) die "backup placement is '$(jq -r '.placementState // "empty"' "${bj}")' — the vault pulls a PBS of the Site's own; there is none (ADR-012 §1.2/§1.3)" ;;
    esac
    jq -e '(.host.operatorSshKeys // []) | length > 0' "${SAT_CFG}" >/dev/null \
        || die "${INSTANCE} records no operator key — after lockdown nothing else could log in"
    sat_ssh true || die "the mothership cannot log in to ${ADDRESS} — lockdown runs over its key"
    command -v backup-manager >/dev/null || die "backup-manager not on PATH"

    local pbs fp store authid="${SAT_NAME}@pbs" pw home_pub srv
    pbs="$(sat_home_pbs_address)"
    [[ -n "${pbs}" ]] || die "cannot resolve the Site's PBS to an address — set vault.pull.homePbsHost"
    fp="$(sat_pbs_fingerprint "${pbs}")"
    [[ -n "${fp}" ]] || die "cannot read the PBS certificate's fingerprint on ${pbs} (root by the mothership's key: proxmox-backup-manager cert info)"
    store="$(jq -r '.pbsStorageName // "tappaas_backup"' "${bj}")"
    srv="$(sat_opnsense_uuid server)"
    [[ -n "${srv}" ]] || die "OPNsense has no tunnel server tappaas-edge-${SAT_NAME} — is ${INSTANCE} wired?"
    home_pub="$(_ow_api "/api/wireguard/server/getServer/${srv}" | jq -r '.server.pubkey // empty')"
    [[ -n "${home_pub}" ]] || die "cannot read the OPNsense end of the tunnel"
    info "${BOLD}Locking ${BL}${INSTANCE}${CL}${BOLD} down as the off-site vault: pulls ${pbs}:${SAT_HOME_PBS_PORT} (${store}) as ${authid}${CL}"

    # 1. home: the read-only login, as a `remote` peer of the satellite's name
    pw="$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40)"
    [[ ${#pw} -ge 32 ]] || die "could not generate a password for ${authid}"
    local place=()
    local c; c="$(jq -r '.physicalLocation.country // empty' "${SAT_CFG}")"
    if [[ -n "${c}" ]]; then
        place=(--country "${c}")
        c="$(jq -r '.physicalLocation.city // empty' "${SAT_CFG}")"; [[ -n "${c}" ]] && place+=(--city "${c}")
        c="$(jq -r '.physicalLocation.building // empty' "${SAT_CFG}")"; [[ -n "${c}" ]] && place+=(--building "${c}")
    fi
    info "  [1/4] the Site's PBS: read-only login ${authid}"
    TAPPAAS_REMOTE_PASSWORD="${pw}" backup-manager peer add remote "${SAT_NAME}" --auth-id "${authid}" \
        ${place[@]+"${place[@]}"} --force \
        || die "could not grant ${authid} read access on the Site's PBS — nothing on the satellite changed"

    # 2. what the satellite is told (rendered as the locked-down config)
    sat_set '.vault = ((.vault // {}) + {pull: (((.vault // {}).pull // {}) + {homePbsHost: $h, homeDatastore: $st, authId: $a, fingerprint: $fp})})' \
        --arg h "${pbs}" --arg st "${store}" --arg a "${authid}" --arg fp "${fp}"
    local cdir tmpcfg; cdir="$(mktemp -d)"; tmpcfg="${cdir}/instance.json"
    jq '.management = "unmanaged" | .roles = ((.roles // []) + ["backup"] | unique)' "${SAT_CFG}" > "${tmpcfg}"
    sat_gen_debian_configs "${tmpcfg}" "${home_pub}" "${cdir}" "${SAT_CICD_PUB}" || die "config rendering failed"
    TAPPAAS_SAT_PBS_TOKEN="${pw}" sat_gen_backup_config "${tmpcfg}" "${cdir}"
    rm -f "${tmpcfg}"
    sat_assemble_debian_deploy "${cdir}" >/dev/null
    sat_assemble_backup_deploy "${cdir}"

    info "  [2/4] OPNsense: edge -> ${pbs}:${SAT_HOME_PBS_PORT}"
    sat_ensure_edge_pbs_rule "${pbs}" >/dev/null || die "could not add the edge -> PBS rule — nothing on the satellite changed"

    info "  [3/4] the satellite: the vault, self-patching, and — last — the mothership's key removed"
    sat_deploy_run "${cdir}" "${SAT_USER}@${ADDRESS}" "${SAT_CICD_PUB%.pub}" \
        provision-debian.sh provision-backup.sh set-management.sh \
        || die "provisioning the vault failed — see above. If the mothership still logs in, fix the cause and run --lockdown again"
    rm -rf "${cdir}"

    info "  [4/4] check and record"
    if sat_ssh true 2>/dev/null; then
        die "the mothership can still log in to ${ADDRESS} — the lockdown did not take; ${INSTANCE} stays managed"
    fi
    sat_set '.management = "unmanaged" | .roles = ((.roles // []) + ["backup"] | unique)'
    info "${GN}✓${CL} ${INSTANCE} is locked down: it pulls the Site's PBS, patches itself, and admits no login from home"
    info "  Only your operator key reaches it now. The sweep skips it; 'module-manager module test ${INSTANCE}' checks it from OPNsense."
}

