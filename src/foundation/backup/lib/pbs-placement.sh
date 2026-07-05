# shellcheck shell=bash
# pbs-placement.sh — backup module placement policy + shim state (ADR-012 P1/P2).
#
# The backup module no longer hardcodes node:tappaas3 / storage:tankc1. Placement
# is a policy in backup.json (.placement):
#
#   auto          discover a `tankc` pool (preferred node first, then any node)
#                 and install PBS there; if none is found anywhere, FALL BACK to
#                 a shim (never fail the install).            [ADR-012 D1]
#   node:<name>   pin PBS to <name>'s tankc; shim if that node has no tankc.
#   shim          no datastore — a marker that still satisfies dependsOn:backup;
#                 promotable in place later (update.sh, P2).  [ADR-012 D2/D3]
#   remote-only   no local PBS at all; back up off-site by push (ADR-012 P4).
#
# The *resolved* placement is recorded back into config/backup.json as
# .placementState (local | shim | remote-only) plus the resolved .node/.storage,
# so pbs-job.sh (pbs_node/pbs_storage_name) and the shim guards read one source
# of truth. Re-running install re-discovers, so this is self-healing/idempotent.
#
# Requires: common-install-routines.sh (get_node_hostname, get_all_node_hostnames,
# info/warn/debug, CONFIG_DIR) sourced first.

PBS_PLACEMENT_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
_pbs_backup_json() { printf '%s\n' "${1:-${PBS_PLACEMENT_CONFIG_DIR}/backup.json}"; }

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# Placement policy from backup.json (.placement), default "auto".
placement_policy() {
    local f; f="$(_pbs_backup_json "${1:-}")"
    jq -r '.placement // "auto"' "$f" 2>/dev/null || echo "auto"
}

# If <policy> is "node:<name>", echo <name> (rc 0); else rc 1.
_placement_node_pin() {
    case "$1" in
        node:?*) printf '%s\n' "${1#node:}" ;;
        *) return 1 ;;
    esac
}

# From `pvesm status` text ($1), echo the first ACTIVE storage whose name starts
# with <prefix> ($2, default "tankc"). Empty if none. Pure (awk over text).
_tankc_pick() {
    local prefix="${2:-tankc}"
    awk -v p="^${prefix}" 'NR>1 && $1 ~ p && $3=="active" { print $1; exit }' <<<"$1"
}

# Node names (one per line) from a `pvesh get /nodes --output-format json` blob.
_pbs_nodes_from_json() { jq -r '.[].node // empty' 2>/dev/null <<<"$1"; }

# Resolved placement state recorded in config (.placementState); empty if unset.
pbs_placement_state() {
    local f; f="$(_pbs_backup_json "${1:-}")"
    jq -r '.placementState // empty' "$f" 2>/dev/null || true
}

# True when the deployed backup module is a shim (no local datastore).
pbs_is_shim() { [[ "$(pbs_placement_state)" == "shim" ]]; }

# ── Cluster probes (ssh — not unit-tested) ───────────────────────────

# Echo the active tankc storage id on <node> ($1) in <zone> ($2, default mgmt),
# or empty. Unreachable node / no pvesm ⇒ empty (never fails — auto tolerates it).
pbs_probe_tankc() {
    local node="$1" zone="${2:-mgmt}" prefix="${3:-tankc}" out
    out="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesm status" 2>/dev/null)" || return 0
    _tankc_pick "$out" "$prefix"
}

# Current cluster node names (one per line): ask a reachable mgmt node's pvesh,
# falling back to site.json membership when the cluster is unreachable.
pbs_cluster_nodes() {
    local node="$1" zone="${2:-mgmt}" json
    json="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "pvesh get /nodes --output-format json" 2>/dev/null)" \
        && [[ -n "$json" ]] && { _pbs_nodes_from_json "$json"; return 0; }
    get_all_node_hostnames
}

# Resolve a placement policy to a concrete outcome. Echoes ONE line on stdout
# (diagnostics stay off stdout so callers can parse it):
#   "local <node> <storage>"   → realize PBS on <node>'s <storage>
#   "shim"                     → no datastore
#   "remote-only"              → off-site push only (P4)
# Args: <policy> <preferred-node> [zone]
pbs_discover_placement() {
    local policy="$1" preferred="$2" zone="${3:-mgmt}" pin store node
    case "$policy" in
        shim)        printf 'shim\n'; return 0 ;;
        remote-only) printf 'remote-only\n'; return 0 ;;
    esac
    if pin="$(_placement_node_pin "$policy")"; then
        store="$(pbs_probe_tankc "$pin" "$zone")"
        [[ -n "$store" ]] && { printf 'local %s %s\n' "$pin" "$store"; return 0; }
        printf 'shim\n'; return 0
    fi
    # auto: preferred node first, then any other cluster node.
    store="$(pbs_probe_tankc "$preferred" "$zone")"
    [[ -n "$store" ]] && { printf 'local %s %s\n' "$preferred" "$store"; return 0; }
    while IFS= read -r node; do
        [[ -n "$node" && "$node" != "$preferred" ]] || continue
        store="$(pbs_probe_tankc "$node" "$zone")"
        [[ -n "$store" ]] && { printf 'local %s %s\n' "$node" "$store"; return 0; }
    done < <(pbs_cluster_nodes "$preferred" "$zone")
    printf 'shim\n'
}

# Persist the resolved placement into config/backup.json: .placementState=<mode>
# and (for local) the resolved .node/.storage. Idempotent. Args: <mode> [node] [storage]
pbs_write_placement_state() {
    local mode="$1" node="${2:-}" storage="${3:-}" f tmp
    f="$(_pbs_backup_json)"
    [[ -f "$f" ]] || { warn "pbs_write_placement_state: ${f} missing"; return 1; }
    tmp="$(mktemp)"
    jq --arg m "$mode" --arg n "$node" --arg s "$storage" '
        .placementState = $m
        | (if $n != "" then .node = $n else . end)
        | (if $s != "" then .storage = $s else . end)
    ' "$f" >"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
