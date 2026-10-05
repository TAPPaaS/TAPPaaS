#!/usr/bin/env bash
# nfs-service.sh — what install-, update-, delete- and test-service.sh of storage:nfs
# share (ADR-029 v0.9). Sourced by them after common-install-routines.sh. Not a
# dispatch target itself.
#
# CONSUMER is the consuming module ($1 of the service script). Shares are read from
# config/shares.json; servers are driven through nfs-converge.sh (their hooks), never
# reached from here directly.

NFS_SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/nfs-lib.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-lib.sh"
# shellcheck source=../../lib/nfs-guest.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-guest.sh"
# shellcheck source=../../lib/nfs-converge.sh disable=SC1091
. "${NFS_SERVICE_DIR}/../../lib/nfs-converge.sh"

# nfs_service_check <consumer> — every mount passes its shape check and, where its
# share exists, the two-key check (D3, D11). Prints the problems; rc 1 when there
# is any. A pending mount is reported, not refused.
nfs_service_check() {
    local consumer="$1" m problems rc=0 st
    while IFS= read -r m <&3; do
        [[ -n "${m}" ]] || continue
        if ! problems="$(nfs_check_mount "${consumer}" "${m}")"; then
            while IFS= read -r p; do [[ -n "${p}" ]] && error "  ${p}"; done <<< "${problems}"
            rc=1; continue
        fi
        st="$(nfs_mount_status "${m}")"
        [[ "${st}" == "pending" ]] && info "  $(jq -r .path <<< "${m}"): share $(jq -r .share <<< "${m}") is not declared on any server — pending, the directory stays local (ADR-029 D11)"
    done 3< <(nfs_mounts "${consumer}")
    return "${rc}"
}

# nfs_shares_granting <consumer> — the shares that grant the consumer, one name per
# line. Their client lists are the ones that may hold its address (D16).
nfs_shares_granting() { nfs_shares | jq -r --arg c "$1" 'select(.grants[$c] != null) | .name'; }

# nfs_service_reconverge <consumer> [exclude] — every share that grants the consumer
# converges: its server builds it, the client list holds the consumer exactly when it
# mounts the share (D16), the alias follows. With "exclude" the consumer is left out
# whatever its config says — the delete case, where the config still exists. Each
# server once; never notifying consumers back (NFS_NO_REVERSE).
nfs_service_reconverge() {
    local consumer="$1" exclude="${2:-}" name server rc=0
    local -A done=()
    local -a ex=()
    [[ -n "${exclude}" ]] && ex=("${consumer}")
    while IFS= read -r name <&3; do
        [[ -n "${name}" ]] || continue
        server="$(nfs_find_share "${name}")" || continue
        if [[ -z "${done[${server}]:-}" ]]; then
            done["${server}"]=1
            NFS_NO_REVERSE=1 nfs_converge_server "${server}" "${ex[@]}" || rc=1
        fi
        nfs_ensure_alias "${name}" "${server}" || rc=1
    done 3< <(nfs_shares_granting "${consumer}")
    return "${rc}"
}

# nfs_service_ensure_subdir <mount-json> — the mount's subdir exists in its share,
# owned by the share's owner (D15), made by the server's hook. A registered server's
# or a literal share's subdir must already exist — TAPPaaS does not write to a server
# it does not manage — and the mount itself shows whether it does.
nfs_service_ensure_subdir() {
    local m="$1" subdir kind name server out
    subdir="$(jq -r '.subdir // empty' <<< "${m}")"
    [[ -n "${subdir}" ]] || return 0
    read -r kind name _ < <(nfs_parse_share_ref "$(jq -r .share <<< "${m}")") || return 1
    [[ "${kind}" == "named" ]] || return 0
    server="$(nfs_find_share "${name}")" || return 0
    [[ "$(nfs_server_kind "${server}")" == "hook" ]] || return 0
    out="$("$(nfs_server_hook "${server}")" subdir "${server}" "${name}" "${subdir}")" \
        || { error "  ${name}/${subdir}: could not be created on ${server}"; return 1; }
    [[ "${out}" == *created* ]] && info "  ${GN}✓${CL} ${name}/${subdir}: created, owned by the share's owner"
    return 0
}

# nfs_service_rules <consumer> — the consumer's NFS update owns its firewall path
# (D11, v0.9): when a mount it can make now crosses the firewall, recompile its
# network:rules first. A share that arrived after the consumer (and the update a
# grant triggers) otherwise had no rule, and the mount timed out.
nfs_service_rules() {
    local consumer="$1" m need=0
    while IFS= read -r m <&3; do
        [[ -n "${m}" ]] || continue
        [[ "$(nfs_mount_status "${m}")" == "pending" ]] && continue
        nfs_mount_crosses_zone "${consumer}" "${m}" && { need=1; break; }
    done 3< <(nfs_mounts "${consumer}")
    [[ "${need}" -eq 1 ]] || return 0
    rules-manager --no-ssl-verify reconcile "${consumer}" >/dev/null \
        || { error "  ${consumer}: its firewall rules did not compile — the share is not reachable through the firewall"; return 1; }
    debug "  ${consumer}: firewall rules recompiled for its NFS mounts"
}

# nfs_guest_facts <target> <path> — key=value facts about a mount point in the guest,
# or "unreachable=yes" when the guest does not answer. Never fails the caller: the
# service scripts run under set -e, and a probe that failed used to end an install
# without a word.
nfs_guest_facts() {
    local out
    out="$(nfs_guest_probe_script "$2" | tappaas_ssh_guest -o BatchMode=yes -o ConnectTimeout=15 "$1" "sudo bash -s" 2>/dev/null | tail -1)" || true
    [[ "${out}" == mounted=* ]] && printf '%s\n' "${out}" || printf 'unreachable=yes\n'
}

# nfs_fact <facts> <key>
nfs_fact() { sed -n "s/.*\b$2=\([^ ]*\).*/\1/p" <<< "$1"; }

# nfs_service_converge <consumer> — install and update are one reconcile (ADR-020):
# the guest ends up with exactly the mounts its config declares.
#
#   1. refuse what is wrong (D3, D11); report what is pending
#   2. the servers that grant the consumer converge (D11, D16)
#   3. per mount: a pending one that was already mounted is an error (D14: no way
#      back); a healthy one drops its .pre-nfs; one that is newly available is
#      mounted — or, when its directory holds data, migrated into with consent
#   4. the guest's generated mount list is rewritten (D10)
nfs_service_converge() {
    local consumer="$1" target os m path src v access req status facts lines="" rc=0
    nfs_service_check "${consumer}" || { error "storage:nfs: ${consumer}'s mounts are refused (above) — nothing was changed"; return 1; }
    [[ "$(nfs_consumer_os "${consumer}")" != "other" ]] || { error "storage:nfs mounts only NixOS and Debian guests (ADR-029 D10)"; return 1; }
    nfs_service_reconverge "${consumer}" || { error "storage:nfs: a share's server did not converge (above)"; return 1; }
    nfs_service_rules "${consumer}" || return 1
    target="$(nfs_consumer_target "${consumer}")" \
        || { warn "  ${consumer} has no vmname — no guest to write mounts into"; return 0; }
    os="$(nfs_consumer_os "${consumer}")"
    nfs_guest_ready "${target}" \
        || { error "  ${target#*@} does not accept ssh with passwordless sudo after 5 minutes — its mounts were not written"; return 1; }

    while IFS= read -r m <&3; do
        [[ -n "${m}" ]] || continue
        IFS=$'\t' read -r path src v access req status < <(nfs_resolve_mount "${m}")
        facts="$(nfs_guest_facts "${target}" "${path}")"
        if [[ "${status}" == "pending" ]]; then
            # Still mounted — or an automount still declared — from a share that is
            # no longer declared: the D14 "no way back" case.
            local gone; gone="$(nfs_fact "${facts}" mounted)"
            [[ -n "${gone}" || "$(nfs_fact "${facts}" autofs)" != "yes" ]] || gone="$(nfs_fact "${facts}" fstab)"
            if [[ -n "${gone}" ]]; then
                error "  ${path}: share $(jq -r .share <<< "${m}") is gone, but ${path} is still mounted from it — never a silent fallback to a local directory (ADR-029 D14). Declare the share again, or remove the mount."
                rc=1
                # Keep the guest's entry as it is: dropping it would unmount on the
                # next rebuild and start the app on an empty directory.
                lines+="${path}"$'\t'"${gone}"$'\t4.2\t'"${access}"$'\t'"${req}"$'\tavailable\n'
            else
                lines+="${path}"$'\t'"${src}"$'\t'"${v}"$'\t'"${access}"$'\t'"${req}"$'\tpending\n'
            fi
            continue
        fi
        local line="${path}"$'\t'"${src}"$'\t'"${v}"$'\t'"${access}"$'\t'"${req}"$'\t'
        nfs_service_ensure_subdir "${m}" || { rc=1; lines+="${line}pending"$'\n'; continue; }
        local mounted; mounted="$(nfs_fact "${facts}" mounted)"
        if [[ "${mounted}" == "${src}" ]]; then
            lines+="${line}${status}"$'\n'
            nfs_service_drop_prenfs "${target}" "${path}" "${access}" "$(nfs_fact "${facts}" prenfs)" || rc=1
            continue
        fi
        if [[ "$(nfs_fact "${facts}" autofs)" == "yes" && "$(nfs_fact "${facts}" fstab)" == "${src}" ]]; then
            # The share is the guest's mount here, but would not mount just now (its
            # server is down, or the network): nothing to migrate, nothing to change.
            warn "  ${path}: the share is this guest's mount, but it did not mount just now — is its server up?"
            lines+="${line}${status}"$'\n'
            continue
        fi
        if [[ "$(nfs_fact "${facts}" local)" == "yes" ]]; then
            # The directory holds data: it is migrated into the share, or it stays
            # OUT of the guest's mount list — a rebuild must never mount the share
            # over it and hide that data (D14).
            if nfs_service_migrate "${consumer}" "${target}" "${m}" "${src}" "${v}" "${access}" "$(nfs_fact "${facts}" nfs)" \
               && [[ -n "$(nfs_fact "$(nfs_guest_facts "${target}" "${path}")" mounted)" ]]; then
                lines+="${line}${status}"$'\n'
            else
                [[ "${NFS_MIGRATE_RC:-0}" -eq 0 ]] || rc=1
                lines+="${line}pending"$'\n'
            fi
            continue
        fi
        # Empty, absent, or mounted from another source: the rewritten mount list
        # below makes it right on the guest's next rebuild.
        lines+="${line}${status}"$'\n'
    done 3< <(nfs_mounts "${consumer}")

    nfs_service_write_guest "${consumer}" "${target}" "${os}" "${lines}" || rc=1
    return "${rc}"
}

# nfs_service_drop_prenfs <target> <path> <access> <prenfs> — D14: the update after
# a migration, with the mount active and working, removes the local copy.
nfs_service_drop_prenfs() {
    local target="$1" path="$2" access="$3" prenfs="$4" probe
    [[ "${prenfs}" == "yes" ]] || return 0
    probe="${path}/.tappaas-nfs-probe-$$"
    if [[ "${access}" == "rw" ]]; then
        tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo timeout 30 sh -c 'touch \"${probe}\" && rm -f \"${probe}\"'" 2>/dev/null \
            || { warn "  ${path}: mounted but not writable — ${path}.pre-nfs is kept"; return 0; }
    else
        tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo timeout 30 ls '${path}' >/dev/null" 2>/dev/null \
            || { warn "  ${path}: mounted but not readable — ${path}.pre-nfs is kept"; return 0; }
    fi
    tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo rm -rf --one-file-system '${path}.pre-nfs'" \
        || { error "  ${path}: could not remove ${path}.pre-nfs"; return 1; }
    info "  ${GN}✓${CL} ${path}: the share is healthy — the local copy ${path}.pre-nfs is removed (ADR-029 D14)"
}

# nfs_service_migrate <consumer> <target> <mount-json> <source> <version> <access>
# <nfs-ready> — D14: move the directory's content into the share, then mount it.
nfs_service_migrate() {
    local consumer="$1" target="$2" m="$3" src="$4" v="$5" access="$6" ready="$7" path units out rc
    path="$(jq -r .path <<< "${m}")"
    NFS_MIGRATE_RC=0
    if ! nfs_consent "${consumer}"; then
        warn "  ${path}: share $(jq -r .share <<< "${m}") is available and ${path} holds data — migration pending: it stops the app, so it needs ${consumer}'s rebootOk or --allow-disruption (ADR-029 D14)"
        return 1
    fi
    if [[ "${ready}" != "yes" ]]; then
        warn "  ${path}: migration pending — the guest cannot mount NFS yet; its next rebuild adds the support this update writes, and the update after that migrates"
        return 1
    fi
    units="$(jq -r '(.stopUnits // []) | join(" ")' <<< "${m}")"
    info "  ${path}: migrating into $(jq -r .share <<< "${m}")${units:+ (stopping ${units})}"
    out="$(nfs_migrate_script "${path}" "${src}" "$(nfs_runtime_options "${v}" "${access}")" "${units}" \
            "$(jq -r '.stopCommand // empty' <<< "${m}")" "$(jq -r '.startCommand // empty' <<< "${m}")" \
          | tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo bash -s" 2>&1)"
    rc=$?
    NFS_MIGRATE_RC="${rc}"
    while IFS= read -r l; do [[ -n "${l}" ]] && info "    ${l}"; done <<< "${out}"
    case "${rc}" in
        0) info "  ${GN}✓${CL} ${path}: migrated — ${path}.pre-nfs goes with the next healthy update" ;;
        3) error "  ${path}: not migrated — the share already holds data, and the two are never merged; resolve by hand (ADR-029 D14)" ;;
        4) error "  ${path}: not migrated — something not in stopUnits/stopCommand still has files open (above); the app is running again on its local data" ;;
        *) error "  ${path}: migration failed (exit ${rc}) — the app is running again on its local data" ;;
    esac
    return "${rc}"
}

# nfs_service_write_guest <consumer> <target> <os> <resolved-lines> — the guest's
# generated mount list: the NixOS fragment (applied by the rebuild that install and
# update run after the services) or Debian's marked fstab block (applied now).
# Present whenever the consumer declares mounts, so NFS support is in the guest
# before a pending share arrives (D14); removed when it declares none.
nfs_service_write_guest() {
    local consumer="$1" target="$2" os="$3" lines="$4" tmp
    tmp="$(mktemp)"
    case "${os}" in
        nixos)
            if [[ -z "${lines//[$'\n']/}" ]]; then
                tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo rm -f ${NFS_GUEST_FRAGMENT}" \
                    || { rm -f "${tmp}"; error "  could not remove ${NFS_GUEST_FRAGMENT} from ${target#*@}"; return 1; }
                info "  ${GN}✓${CL} ${consumer}: no mounts — ${NFS_GUEST_FRAGMENT} removed (applied by its next rebuild)"
            else
                nfs_render_nixos "${lines}" > "${tmp}"
                if tappaas_ssh_guest -o BatchMode=yes "${target}" "cat ${NFS_GUEST_FRAGMENT} 2>/dev/null" | cmp -s - "${tmp}"; then
                    debug "  ${consumer}: ${NFS_GUEST_FRAGMENT} unchanged"
                else
                    tappaas_scp_guest -o BatchMode=yes "${tmp}" "${target}:/tmp/tappaas-nfs.nix" \
                        && tappaas_ssh_guest -o BatchMode=yes "${target}" \
                            "sudo install -m 0644 /tmp/tappaas-nfs.nix ${NFS_GUEST_FRAGMENT} && rm -f /tmp/tappaas-nfs.nix" \
                        || { rm -f "${tmp}"; error "  could not write ${NFS_GUEST_FRAGMENT} on ${target#*@}"; return 1; }
                    info "  ${GN}✓${CL} ${consumer}: ${NFS_GUEST_FRAGMENT} written (applied by its next rebuild)"
                fi
            fi ;;
        debian)
            nfs_render_fstab "${lines}" > "${tmp}"
            [[ -n "${lines//[$'\n']/}" ]] || : > "${tmp}"
            tappaas_scp_guest -o BatchMode=yes "${tmp}" "${target}:/tmp/tappaas-nfs.fstab" \
                && tappaas_ssh_guest -o BatchMode=yes "${target}" "sudo bash -s" <<EOF \
                || { rm -f "${tmp}"; error "  could not update /etc/fstab on ${target#*@}"; return 1; }
set -e
command -v mount.nfs >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common rsync psmisc >/dev/null
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
            error "  ${consumer}: storage:nfs mounts only NixOS and Debian guests (ADR-029 D10)"; return 1 ;;
    esac
    rm -f "${tmp}"
}
