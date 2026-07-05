# shellcheck shell=bash
# pbs-push.sh — register a REMOTE PBS as a local push target (ADR-012 P4, #402/#389).
#
# The missing leg of the symmetry (§3.1): the module already PULLS a buddy
# (services/remote, Class A) and RECEIVES a client's push (services/external,
# Class B). Here WE are the source that PUSHES to someone else's PBS — the mirror
# of external-receive, seen from the sender.
#
# Used by `remote-only` sites (single node / no local PBS, §3.4): the remote PBS
# is registered as a Proxmox `pbs` storage and the managed vzdump backup job
# writes VM backups straight there. The credential we hold is WRITE-NO-DELETE —
# the REMOTE grants it (its own `add-external`) and the REMOTE owns prune /
# retention / immutability. So a compromise here can add snapshots but cannot
# erase the off-site copy: the §3.5 append-only invariant, enforced remote-side.
#
# Requires: common-install-routines.sh (get_node_hostname, info/warn/die,
# colours) sourced first.

# ── Pure helper (no cluster access — unit-testable) ──────────────────

# Local Proxmox storage name for a push target <name>.
_pbs_push_storage_name() { printf 'offsite-%s\n' "$1"; }

# ── Cluster ops (mgmt node; pvesm) ───────────────────────────────────

# True if Proxmox storage <name> already exists (queried on a mgmt node).
_pbs_pvesm_has() {
    local name="$1" zone="${2:-mgmt}" node
    node="$(get_node_hostname 0)"
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm status --storage ${name}" >/dev/null 2>&1
}

# Register (idempotently) a remote PBS as a Proxmox `pbs` storage so vzdump can
# write to it. Runs on a mgmt node. %q-quotes the argv so a password with
# specials survives the remote re-parse. Args:
#   name host datastore namespace username password [fingerprint] [port] [zone]
pbs_push_storage_ensure() {
    local name="$1" host="$2" store="$3" ns="$4" user="$5" pw="$6" fp="${7:-}" port="${8:-}" zone="${9:-mgmt}"
    local sname node cmd
    sname="$(_pbs_push_storage_name "$name")"
    node="$(get_node_hostname 0)"
    if _pbs_pvesm_has "$sname" "$zone"; then
        info "  push storage ${BL}${sname}${CL} already configured"
        return 0
    fi
    local -a a=(pvesm add pbs "$sname" --server "$host" --datastore "$store"
                --username "$user" --password "$pw" --content backup)
    [[ -n "$ns" ]]   && a+=(--namespace "$ns")
    [[ -n "$fp" ]]   && a+=(--fingerprint "$fp")
    [[ -n "$port" ]] && a+=(--port "$port")
    printf -v cmd '%q ' "${a[@]}"
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "${cmd}" \
        && info "  ${GN}✓${CL} registered push storage ${BL}${sname}${CL} → ${host}:${store}/${ns}"
}

# Remove the local push storage for <name> (idempotent). Does NOT touch anything
# on the remote — the off-site data and its retention are the remote's to manage.
pbs_push_storage_delete() {
    local name="$1" zone="${2:-mgmt}" sname node
    sname="$(_pbs_push_storage_name "$name")"
    node="$(get_node_hostname 0)"
    _pbs_pvesm_has "$sname" "$zone" || { info "  push storage ${sname} not present"; return 0; }
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm remove ${sname}" \
        && info "  ${GN}✓${CL} removed push storage ${sname} (off-site data untouched)"
}
