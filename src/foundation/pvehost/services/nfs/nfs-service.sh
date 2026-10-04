#!/usr/bin/env bash
# nfs-service.sh — what install-, update- and delete-service.sh share (ADR-029).
# Sourced by them after common-install-routines.sh. Not a dispatch target itself.
#
# CONSUMER is the consuming module ($1 of the service script). Its config is in
# config/<CONSUMER>.json; a node is always read from its own file, never through
# pn_load (see nfs-guest.sh).

NFS_SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/pvehost-lib.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/pvehost-lib.sh"
# shellcheck source=../../lib/nfs-lib.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-lib.sh"
# shellcheck source=../../lib/nfs-node.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-node.sh"
# shellcheck source=../../lib/nfs-guest.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-guest.sh"

# nfs_service_check <consumer> — every mount passes its own shape check and the
# two-key check (D3, D11). Prints the problems; rc 1 when there is any.
nfs_service_check() {
    local consumer="$1" m problems rc=0
    while IFS= read -r m; do
        [[ -n "${m}" ]] || continue
        if ! problems="$(nfs_check_mount "${consumer}" "${m}")"; then
            while IFS= read -r p; do [[ -n "${p}" ]] && error "  ${p}"; done <<< "${problems}"
            rc=1
        fi
    done < <(nfs_mounts "${consumer}")
    return "${rc}"
}

# nfs_service_build_exports <consumer> — D11: a consumer never creates an export,
# but a DECLARED one its mounts name is built now, through the node's own
# reconcile — which also adds this consumer to the node's client lists. Runs each
# node once, in a subshell so INSTANCE/ADDRESS never leak into the caller.
nfs_service_build_exports() {
    local consumer="$1" m kind host name done_nodes=" " rc=0
    while IFS= read -r m; do
        [[ -n "${m}" ]] || continue
        read -r kind host name < <(nfs_parse_share_ref "$(jq -r .share <<< "${m}")") || continue
        [[ "${kind}" == "named" ]] || continue
        [[ "${done_nodes}" == *" ${host} "* ]] && continue
        done_nodes+="${host} "
        if ! nfs_instance_managed "${host}"; then
            info "  ${host} is a registered, unmanaged server — nothing is built there; its export table must grant ${consumer} (pvehost nfs show ${host})"
            continue
        fi
        ( INSTANCE="${host}"; ADDRESS="$(nfs_instance_address "${host}")"
          [[ -n "${ADDRESS}" ]] || { error "  ${host}: no address in config/${host}.json"; exit 1; }
          pn_reachable || { error "  ${host}: root@${ADDRESS} does not accept the mothership's key"; exit 1; }
          nfs_node_reconcile ) || rc=1
    done < <(nfs_mounts "${consumer}")
    return "${rc}"
}

# nfs_service_write_guest <consumer> — write the consumer's mounts into its guest:
# the NixOS fragment (applied by the rebuild install/update run after the
# services), or the marked fstab block on Debian (applied now). No mounts → the
# fragment/block is removed.
nfs_service_write_guest() {
    local consumer="$1" target os lines="" m tmp
    target="$(nfs_consumer_target "${consumer}")" \
        || { warn "  ${consumer} has no vmname — no guest to write mounts into"; return 0; }
    os="$(nfs_consumer_os "${consumer}")"
    while IFS= read -r m; do
        [[ -n "${m}" ]] || continue
        lines+="$(nfs_resolve_mount "${m}")"$'\n' || return 1
    done < <(nfs_mounts "${consumer}")
    tmp="$(mktemp)"
    case "${os}" in
        nixos)
            if [[ -z "${lines//[$'\n']/}" ]]; then
                tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo rm -f ${NFS_GUEST_FRAGMENT}" \
                    || { rm -f "${tmp}"; error "  could not remove ${NFS_GUEST_FRAGMENT} from ${target#*@}"; return 1; }
                info "  ${GN}✓${CL} ${consumer}: no mounts — ${NFS_GUEST_FRAGMENT} removed (applied by its next rebuild)"
            else
                nfs_render_nixos "${lines}" > "${tmp}"
                tappaas_scp_guest -o BatchMode=yes "${tmp}" "${target}:/tmp/tappaas-nfs.nix" \
                    && tappaas_ssh_guest -o BatchMode=yes "${target}" \
                        "sudo install -m 0644 /tmp/tappaas-nfs.nix ${NFS_GUEST_FRAGMENT} && rm -f /tmp/tappaas-nfs.nix" \
                    || { rm -f "${tmp}"; error "  could not write ${NFS_GUEST_FRAGMENT} on ${target#*@}"; return 1; }
                info "  ${GN}✓${CL} ${consumer}: ${NFS_GUEST_FRAGMENT} written (applied by its next rebuild)"
            fi ;;
        debian)
            nfs_render_fstab "${lines}" > "${tmp}"
            [[ -n "${lines//[$'\n']/}" ]] || : > "${tmp}"
            tappaas_scp_guest -o BatchMode=yes "${tmp}" "${target}:/tmp/tappaas-nfs.fstab" \
                && tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo bash -s" <<EOF \
                || { rm -f "${tmp}"; error "  could not update /etc/fstab on ${target#*@}"; return 1; }
set -e
command -v mount.nfs >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common >/dev/null
awk -v b='${NFS_FSTAB_BEGIN}' -v e='${NFS_FSTAB_END}' '\$0 == b {s = 1; next} \$0 == e {s = 0; next} !s' /etc/fstab > /etc/fstab.tappaas-nfs
cat /tmp/tappaas-nfs.fstab >> /etc/fstab.tappaas-nfs
mv /etc/fstab.tappaas-nfs /etc/fstab
rm -f /tmp/tappaas-nfs.fstab
awk '\$3 == "nfs" {print \$2}' /etc/fstab | xargs -r mkdir -p
systemctl daemon-reload
systemctl restart remote-fs.target
EOF
            info "  ${GN}✓${CL} ${consumer}: /etc/fstab block updated and applied" ;;
        *)
            rm -f "${tmp}"
            error "  ${consumer}: pvehost:nfs mounts only NixOS and Debian guests (ADR-029 D10)"; return 1 ;;
    esac
    rm -f "${tmp}"
}
