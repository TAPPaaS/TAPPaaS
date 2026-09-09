# shellcheck shell=bash
# pbs-storage.sh — register a PBS as a Proxmox `pbs` storage (ADR-012).
#
# Two callers need the exact same mechanic and used to carry their own copy:
#
#   pbs-push.sh      an off-site PBS we PUSH to, registered as `offsite-<name>`
#   pbs-external.sh  an externally-managed PBS we CONSUME (§1.3/#456), registered
#                    under the module's own pbsStorageName so the existing job
#                    machinery targets it with no further wiring
#
# The difference between them is the storage NAME and who owns the datastore —
# not the registration, so the registration lives here once.
#
# Runs on a mgmt node over ssh. The argv is %q-quoted so a password with shell
# specials survives the remote re-parse. Nothing here ever creates a datastore
# or touches remote contents: registering is a local, reversible act.
#
# Requires: common-install-routines.sh (get_node_hostname, info/warn, colours).

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# Host part of a PBS URL: strips a scheme, a :port, and any path.
#   pbs.example.org            → pbs.example.org
#   https://pbs.example:8007/  → pbs.example
_pbs_url_host() {
    local u="${1:-}"
    u="${u#*://}"     # drop scheme
    u="${u%%/*}"      # drop path
    printf '%s\n' "${u%%:*}"
}

# Port part of a PBS URL, or empty when none is given (PBS defaults to 8007).
_pbs_url_port() {
    local u="${1:-}"
    u="${u#*://}"; u="${u%%/*}"
    case "$u" in
        *:*) printf '%s\n' "${u##*:}" ;;
        *)   printf '\n' ;;
    esac
}

# ── Cluster ops (mgmt node; pvesm) ───────────────────────────────────

# True if Proxmox storage <name> already exists (queried on a mgmt node).
_pbs_pvesm_has() {
    local name="$1" zone="${2:-mgmt}" node
    node="$(get_node_hostname 0)"
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm status --storage ${name}" >/dev/null 2>&1
}

# Register (idempotently) a PBS as a Proxmox `pbs` storage so vzdump can write
# to it. Never creates a datastore — the datastore must already exist on that
# PBS. Args: sname host datastore namespace username password [fp] [port] [zone]
pbs_storage_register() {
    local sname="$1" host="$2" store="$3" ns="$4" user="$5" pw="$6" fp="${7:-}" port="${8:-}" zone="${9:-mgmt}"
    local node cmd
    node="$(get_node_hostname 0)"
    if _pbs_pvesm_has "$sname" "$zone"; then
        info "  storage ${BL}${sname}${CL} already configured"
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
        && info "  ${GN}✓${CL} registered storage ${BL}${sname}${CL} → ${host}:${store}${ns:+/${ns}}"
}

# Remove a registered PBS storage (idempotent). Local only: the datastore and
# its retention belong to whoever owns that PBS, and are never touched here.
pbs_storage_unregister() {
    local sname="$1" zone="${2:-mgmt}" node
    node="$(get_node_hostname 0)"
    _pbs_pvesm_has "$sname" "$zone" || { info "  storage ${sname} not present"; return 0; }
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm remove ${sname}" \
        && info "  ${GN}✓${CL} removed storage ${sname} (remote data untouched)"
}
