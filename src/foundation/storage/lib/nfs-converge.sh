#!/usr/bin/env bash
# nfs-converge.sh — make the Site match config/shares.json (ADR-029 v0.9 D17, D19):
# drive each server's NFS hook, keep each share's alias pointing at its server,
# and tell consumers when a share became available to them. The one place this is
# done: storage-manager's verbs, the storage module's update (the sweep) and the
# storage:nfs service all come here.
#
# As a command (storage-manager calls it):
#   nfs-converge.sh share <name> [--exclude <consumer>]... [--notify | --notify-only <consumer>...]
#   nfs-converge.sh server <instance> [--exclude <consumer>]...
#   nfs-converge.sh all                     every share, every server (the sweep)
#   nfs-converge.sh drop <name> <server>    after a share's declaration is deleted
#   nfs-converge.sh subdir <share> <subdir>
#   nfs-converge.sh purge <name> <server>
#   nfs-converge.sh notify <name>
# As a library: source it after common-install-routines.sh and nfs-lib.sh.

NFS_CONVERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# nfs_server_kind <instance> — hook (a managed Host whose module ships the NFS
# server hook), unmanaged (a registered server: nothing to build), nohook (managed,
# but its module cannot serve), or missing (no such instance).
nfs_server_kind() {
    local cfg="${NFS_CONFIG_DIR}/$1.json"
    [[ -f "${cfg}" ]] || { echo missing; return; }
    nfs_instance_managed "$1" || { echo unmanaged; return; }
    [[ -n "$(nfs_server_hook "$1")" ]] && echo hook || echo nohook
}

# nfs_server_hook <instance> — the instance's module's NFS server hook, found through
# the module's source directory (ADR-026 D6); empty when there is none.
nfs_server_hook() {
    local src
    src="$(jq -r '.moduleSource // .location // empty' "${NFS_CONFIG_DIR}/$1.json" 2>/dev/null)"
    [[ -n "${src}" && -x "${src}/storage/nfs-server.sh" ]] && printf '%s\n' "${src}/storage/nfs-server.sh"
}

# nfs_converge_server <instance> [consumer-to-exclude...] — the server builds what is
# declared for it. A registered server builds nothing.
nfs_converge_server() {
    local inst="$1" kind hook c; shift
    local -a args=()
    for c in "$@"; do args+=(--exclude "${c}"); done
    kind="$(nfs_server_kind "${inst}")"
    case "${kind}" in
        hook)      hook="$(nfs_server_hook "${inst}")"; "${hook}" converge "${inst}" "${args[@]}" ;;
        unmanaged) debug "  ${inst}: a registered, unmanaged server — nothing to build there (ADR-029 D2a)" ;;
        nohook)    error "  ${inst}: its module ships no NFS server hook — it cannot serve shares (ADR-029 D19)"; return 1 ;;
        missing)   error "  ${inst}: no config/${inst}.json — not a module instance"; return 1 ;;
    esac
}

# nfs_alias_target <server> — "<host> <domain>" for dns-manager: the server's address
# when it is an FQDN, else its <instance>.<zone>.internal name (a CNAME cannot follow
# an IP).
nfs_alias_target() {
    local cfg="${NFS_CONFIG_DIR}/$1.json" addr zone
    addr="$(jq -r '.address // empty' "${cfg}" 2>/dev/null)"
    if [[ "${addr}" == *.* && ! "${addr}" =~ ^[0-9.]+$ ]]; then
        printf '%s %s\n' "${addr%%.*}" "${addr#*.}"
    else
        zone="$(jq -r '.zone0 // "mgmt"' "${cfg}" 2>/dev/null)"
        printf '%s %s.internal\n' "$1" "${zone}"
    fi
}

# nfs_alias_list — "alias target" pairs from dns-manager, cached for one run.
nfs_alias_list() {
    if [[ -z "${NFS_ALIAS_CACHE+set}" ]]; then
        NFS_ALIAS_CACHE="$(dns-manager --no-ssl-verify alias list 2>/dev/null | awk '$2 == "->" {print $1, $3}')"
    fi
    printf '%s\n' "${NFS_ALIAS_CACHE}"
}

# nfs_ensure_alias <share> <server> — the share alias follows the server (D2b).
nfs_ensure_alias() {
    local alias host domain cur
    alias="$(nfs_share_alias "$1")"
    read -r host domain < <(nfs_alias_target "$2")
    cur="$(nfs_alias_list | awk -v a="${alias}" '$1 == a {print $2}')"
    [[ "${cur}" == "${host}.${domain}" ]] && return 0
    [[ -n "${cur}" ]] && dns-manager --no-ssl-verify alias delete "${alias}" >/dev/null 2>&1
    dns-manager --no-ssl-verify alias add "${alias}" "${host}" "${domain}" >/dev/null \
        || { error "  share $1: could not create the share alias ${alias}"; return 1; }
    unset NFS_ALIAS_CACHE
    info "  ${GN}✓${CL} ${alias} → ${host}.${domain}${cur:+ (was ${cur})}"
}

# nfs_drop_alias <share> [server] — remove the share alias; with a server, only while
# it still follows that server (once a share moved, the alias is the new server's).
nfs_drop_alias() {
    local alias host domain cur
    alias="$(nfs_share_alias "$1")"
    cur="$(nfs_alias_list | awk -v a="${alias}" '$1 == a {print $2}')"
    [[ -n "${cur}" ]] || return 0
    if [[ -n "${2:-}" ]]; then
        read -r host domain < <(nfs_alias_target "$2")
        [[ "${cur}" == "${host}.${domain}" ]] || return 0
    fi
    dns-manager --no-ssl-verify alias delete "${alias}" >/dev/null 2>&1 \
        && { unset NFS_ALIAS_CACHE; info "  ${alias}: removed with its share"; }
}

# nfs_drop_orphan_aliases — remove every share alias (nfs-<share>.<domain>, D2b: the
# storage module's own names) whose share is no longer declared. A declaration that
# went without 'share delete' — a hand edit of shares.json — otherwise left it.
nfs_drop_orphan_aliases() {
    local alias share rc=0 f
    f="$(nfs_shares_file)"
    # Never judge orphans from a file that cannot be read: every alias would look like one.
    [[ ! -e "${f}" ]] || jq -e 'type == "object"' "${f}" >/dev/null 2>&1 \
        || { warn "  ${f} is not readable JSON — share aliases left as they are"; return 1; }
    while read -r alias _; do
        [[ "${alias}" == nfs-*."${NFS_ALIAS_DOMAIN}" ]] || continue
        share="${alias#nfs-}"; share="${share%%.*}"
        nfs_find_share "${share}" >/dev/null 2>&1 && continue
        dns-manager --no-ssl-verify alias delete "${alias}" >/dev/null 2>&1 \
            && info "  ${alias}: removed — share ${share} is no longer declared" \
            || { warn "  ${alias}: could not remove it (share ${share} is no longer declared)"; rc=1; }
    done < <(nfs_alias_list)
    unset NFS_ALIAS_CACHE
    return "${rc}"
}

# nfs_share_consumers <share> — the consumers granted the share that are deployed and
# mount it, one per line.
nfs_share_consumers() {
    local s c
    s="$(nfs_share "$1")" || return 0
    for c in $(jq -r '.grants // {} | keys[]' <<< "${s}"); do
        nfs_is_instance "${c}" && nfs_mounts_share "${c}" "$1" && printf '%s\n' "${c}"
    done
}

# nfs_notify <share> [consumer...] — run the storage:nfs update of every consumer
# that mounts the share (or only of those named: a grant tells the one it added, not
# every consumer already served), so a pending mount migrates now rather than at the
# next sweep (D11). The consent a migration needs travels in TAPPAAS_ALLOW_DISRUPTION.
nfs_notify() {
    local share="$1" c svc="${NFS_CONVERGE_DIR}/../services/nfs/update-service.sh"; shift
    local -a only=("$@")
    while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        if [[ "${#only[@]}" -gt 0 && " ${only[*]} " != *" ${c} "* ]]; then continue; fi
        info "  ${c}: share ${share} is available to it — running its storage:nfs update"
        NFS_NO_REVERSE=1 "${svc}" "${c}" || warn "  ${c}: its storage:nfs update failed (above); the next sweep retries"
    done < <(nfs_share_consumers "${share}")
}

# nfs_converge_share <share> [consumer-to-exclude...] — its server builds it and the
# alias follows. rc 1 when the share is not declared.
nfs_converge_share() {
    local name="$1" server; shift
    server="$(nfs_find_share "${name}")" || { error "  share ${name} is not declared"; return 1; }
    nfs_converge_server "${server}" "$@" && nfs_ensure_alias "${name}" "${server}"
}

# ── command form ───────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    VERB="${1:-}"; shift || true
    REST=("$@"); set --
    . /home/tappaas/bin/common-install-routines.sh
    . "${NFS_CONVERGE_DIR}/nfs-lib.sh"
    set -- "${REST[@]}"
    excludes=(); notify=0; notify_only=(); pos=()
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --exclude) excludes+=("${2:?--exclude needs a consumer}"); shift 2 ;;
            --notify)  notify=1; shift ;;
            --notify-only) notify=1; notify_only+=("${2:?--notify-only needs a consumer}"); shift 2 ;;
            *)         pos+=("$1"); shift ;;
        esac
    done
    case "${VERB}" in
        share)
            [[ "${#pos[@]}" -eq 1 ]] || die "share <name>"
            nfs_converge_share "${pos[0]}" "${excludes[@]}"
            [[ "${notify}" -eq 0 ]] || nfs_notify "${pos[0]}" ${notify_only[@]+"${notify_only[@]}"} ;;
        server)
            [[ "${#pos[@]}" -eq 1 ]] || die "server <instance>"
            nfs_converge_server "${pos[0]}" "${excludes[@]}" ;;
        all)
            rc=0
            for srv in $(nfs_shares | jq -r '.server' | sort -u); do nfs_converge_server "${srv}" || rc=1; done
            while IFS= read -r s; do
                [[ -n "${s}" ]] || continue
                nfs_ensure_alias "$(jq -r .name <<< "${s}")" "$(jq -r .server <<< "${s}")" || rc=1
            done < <(nfs_shares)
            nfs_drop_orphan_aliases || rc=1
            exit "${rc}" ;;
        drop)
            [[ "${#pos[@]}" -eq 2 ]] || die "drop <name> <server>"
            nfs_drop_alias "${pos[0]}" "${pos[1]}"
            nfs_converge_server "${pos[1]}" ;;
        subdir)
            [[ "${#pos[@]}" -eq 2 ]] || die "subdir <share> <subdir>"
            server="$(nfs_find_share "${pos[0]}")" || die "share ${pos[0]} is not declared"
            [[ "$(nfs_server_kind "${server}")" == hook ]] || exit 0
            "$(nfs_server_hook "${server}")" subdir "${server}" "${pos[0]}" "${pos[1]}" ;;
        purge)
            [[ "${#pos[@]}" -eq 2 ]] || die "purge <name> <server>"
            [[ "$(nfs_server_kind "${pos[1]}")" == hook ]] || die "${pos[1]}: TAPPaaS builds nothing there, so there is nothing to purge"
            "$(nfs_server_hook "${pos[1]}")" purge "${pos[1]}" "${pos[0]}" ;;
        notify)
            [[ "${#pos[@]}" -eq 1 ]] || die "notify <name>"
            nfs_notify "${pos[0]}" ;;
        *)  die "usage: nfs-converge.sh share|server|all|drop|subdir|purge|notify ..." ;;
    esac
fi
