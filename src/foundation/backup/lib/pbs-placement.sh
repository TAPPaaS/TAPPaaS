# shellcheck shell=bash
# pbs-placement.sh — backup module placement STATE (ADR-012 v0.3 §2.1/§2.2).
#
# There is no `placement` policy field. `placementState` is the single source of
# truth; the released module ships it EMPTY and install resolves it once:
#
#   (empty)        unresolved — install derives it
#   node:<name>    PBS software + datastore realized on <name>'s tankc pool
#   shim           marker only, no datastore; satisfies dependsOn:backup and is
#                  promoted in place later (update.sh re-derives)
#   external       an externally-managed PBS at .pbsUrl is CONSUMED; nothing is
#                  provisioned. Set at install time and PERMANENT thereafter.
#
# Resolution order (§2.2), implemented by pbs_resolve_placement_state:
#   1. state is already `external`               → keep (forced, sticky)
#   2. state is already `node:<name>`            → keep (idempotent)
#   3. state is empty or `shim`                  → derive: discover a tankc pool
#      (only .node when set — a DISCOVERY CONSTRAINT — else every cluster node);
#      found → node:<name>, not found → shim.
#
# Forcing `external` needs no dedicated flag: install-module.sh's native field
# override stages it before this module runs (D14) —
#   install-module.sh backup --force --placementState external --pbsUrl <url>
#
# Two operator inputs shape resolution, both on backup.json:
#   .node    optional — restrict tankc discovery to ONE named node ("" = all)
#   .pbsUrl  the PBS clients push to (default backup.mgmt.internal)
#
# The RESOLVED node lives in the state itself (`node:<name>`) — not in `.node`,
# which is an operator input the 3-way merge (#207/#581) may legitimately reset.
# `.storage` is written back as the resolved pool (merge-safe: it only differs
# from the release default when discovery actually chose another pool).
#
# Requires: common-install-routines.sh (get_node_hostname, get_all_node_hostnames,
# info/warn/debug, CONFIG_DIR) sourced first.

PBS_PLACEMENT_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
_pbs_backup_json() { printf '%s\n' "${1:-${PBS_PLACEMENT_CONFIG_DIR}/backup.json}"; }

# Default URL clients push to when nothing is configured: the local PBS DNS name.
PBS_DEFAULT_URL="backup.mgmt.internal"

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# Resolved placement state recorded in config (.placementState); empty if unset.
pbs_placement_state() {
    local f; f="$(_pbs_backup_json "${1:-}")"
    jq -r '.placementState // empty' "$f" 2>/dev/null || true
}

# The PBS clients push to (§1.4/§2.1), default backup.mgmt.internal.
pbs_pbs_url() {
    local f; f="$(_pbs_backup_json "${1:-}")"
    jq -r --arg d "${PBS_DEFAULT_URL}" '.pbsUrl // "" | if . == "" then $d else . end' \
        "$f" 2>/dev/null || printf '%s\n' "${PBS_DEFAULT_URL}"
}

# If <state> is "node:<name>", echo <name> (rc 0); else rc 1.
pbs_state_node() {
    case "${1:-}" in
        node:?*) printf '%s\n' "${1#node:}" ;;
        *) return 1 ;;
    esac
}

# True when the deployed backup module is a shim (no datastore anywhere).
pbs_is_shim() { [[ "$(pbs_placement_state "${1:-}")" == "shim" ]]; }

# True when the module consumes an externally-managed PBS (§1.3) — no local
# datastore, but a real one at .pbsUrl, so dependents DO get backed up.
pbs_is_external() { [[ "$(pbs_placement_state "${1:-}")" == "external" ]]; }

# True when a local PBS is realized on a cluster node (state node:<name>).
pbs_is_local() { pbs_state_node "$(pbs_placement_state "${1:-}")" >/dev/null; }

# From `pvesm status` text ($1), echo the first ACTIVE storage whose name starts
# with <prefix> ($2, default "tankc"). Empty if none. Pure (awk over text).
_tankc_pick() {
    local prefix="${2:-tankc}"
    awk -v p="^${prefix}" 'NR>1 && $1 ~ p && $3=="active" { print $1; exit }' <<<"$1"
}

# Node names (one per line) from a `pvesh get /nodes --output-format json` blob.
_pbs_nodes_from_json() { jq -r '.[].node // empty' 2>/dev/null <<<"$1"; }

# True when `pvesm status` text ($1) lists storage <name> ($2) as ACTIVE — an
# exact-name match, unlike _tankc_pick's prefix scan. Used to find which node a
# legacy (pre-v0.3) PBS actually runs on: the one whose configured pool is there.
_pbs_storage_active() {
    awk -v s="$2" 'NR>1 && $1==s && $3=="active" { found=1 } END { exit !found }' <<<"$1"
}

# State of storage <name> ($3) from one `pvesm status --storage <name> 2>&1`
# probe: its output ($1, stderr included) and exit code ($2). Echoes one of
#   active | inactive | missing | unknown
# "unknown" is a probe that did not answer (a timeout, no connection, no line
# for the storage): while vzdump writes to the PBS the status query competes
# with it and reads "inactive" with a 500 error, although nothing is broken
# (#636). Only "missing" and a clean "inactive" say the storage is wrong.
pbs_storage_probe_state() {
    local out="$1" rc="$2" name="$3"
    if [[ "${rc}" == "124" || "${rc}" == "255" ]]; then echo unknown; return; fi
    if grep -qF "storage '${name}' does not exist" <<<"${out}"; then echo missing; return; fi
    if _pbs_storage_active "${out}" "${name}"; then echo active; return; fi
    if ! awk -v s="${name}" '$1==s { f=1 } END { exit !f }' <<<"${out}"; then echo unknown; return; fi
    if grep -qiE "error fetching|timeout|can't connect|^[^ ]*: *500 " <<<"${out}"; then echo unknown; return; fi
    echo inactive
}

# ── Migration: legacy state → v0.3 state (§4.1, D22) ─────────────────
#
# Legacy values written by ADR-012 v0.2 installs:
#   local        → node:<name>, <name> from the legacy .node (the node the PBS
#                  actually runs on). The datastore is LEFT EXACTLY WHERE IT IS —
#                  no move, no dependent reinstall.
#   remote-only  → external, seeding .pbsUrl from the legacy .pushTarget's
#                  remote host when that config exists.
#   (empty)      → left empty; install/update derives it (a pre-ADR-012 install
#                  has no marker at all and is treated as a live local PBS).
#
# The legacy `.placement` policy field is NOT consulted: the 3-way merge drops
# it (a field the release no longer defines — #581 rule 2a) before this module's
# update.sh ever runs, and everything migration needs is in .placementState +
# .node + .pushTarget. Any lingering `.placement` is removed here too.
#
# Pure jq over the config file; idempotent; safe to run on an already-migrated
# config. Echoes the resulting state. Args: [backup.json path]
pbs_migrate_placement_state() {
    local f tmp state node target host new
    f="$(_pbs_backup_json "${1:-}")"
    [[ -f "$f" ]] || return 0
    state="$(jq -r '.placementState // empty' "$f" 2>/dev/null || true)"
    # The node the legacy PBS actually runs on: passed in by the caller (which
    # can probe the cluster — pbs_legacy_pbs_node), else the config's .node.
    node="${2:-}"
    [[ -n "${node}" ]] || node="$(jq -r '.node // empty' "$f" 2>/dev/null || true)"
    new="${state}"
    case "${state}" in
        local)
            [[ -n "${node}" ]] && new="node:${node}" || new="shim"
            ;;
        remote-only)
            new="external"
            target="$(jq -r '.pushTarget // empty' "$f" 2>/dev/null || true)"
            if [[ -n "${target}" ]]; then
                host="$(jq -r '.remoteHost // empty' \
                    "${PBS_PLACEMENT_CONFIG_DIR}/push-${target}.json" 2>/dev/null || true)"
            fi
            ;;
    esac
    tmp="$(mktemp)"
    jq --arg s "${new}" --arg h "${host:-}" '
        del(.placement)
        | (if $s != "" then .placementState = $s else . end)
        | (if $h != "" and ((.pbsUrl // "") == "") then .pbsUrl = $h else . end)
    ' "$f" >"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "${new}"
}

# ── Is the recorded PBS host actually a cluster member? ──────────────
#
# A legacy `placementState: local` says only "PBS is realized here"; it does not
# say the host is in the cluster. A site can perfectly well run PBS on a
# STANDALONE machine registered in DNS (backup.mgmt.internal) — to the client
# modules that is indistinguishable from an in-cluster PBS, which is why it went
# unnoticed. Migrating such an install to `node:<name>` would assert cluster
# membership that does not exist (ADR-022 raises the same objection about the
# meaning of Node).
#
# Pure: does <node> ($1) appear in the newline-separated list ($2)?
_pbs_node_in_list() {
    local want="$1" line
    while IFS= read -r line; do
        [[ "${line}" == "${want}" ]] && return 0
    done <<< "$2"
    return 1
}

# ── Cluster probes (ssh — not unit-tested) ───────────────────────────

# True when <node> is a member of this cluster. Unreachable cluster ⇒ we cannot
# tell, and we say so by returning 2 rather than guessing: a false "not a
# member" would rewrite a perfectly good local placement into an external one.
pbs_node_is_cluster_member() {
    local node="$1" zone="${2:-mgmt}" members
    members="$(pbs_cluster_nodes "$(get_node_hostname 0)" "${zone}")"
    [[ -n "${members}" ]] || return 2
    _pbs_node_in_list "${node}" "${members}"
}

# Record an externally-managed PBS: the host we back up to is not ours to
# manage, so `external` + the URL clients already use is the truthful state.
# Idempotent. Args: <dns-name> [backup.json path]
pbs_adopt_external_pbs() {
    local url="$1" f tmp
    f="$(_pbs_backup_json "${2:-}")"
    [[ -f "$f" ]] || return 1
    tmp="$(mktemp)"
    jq --arg u "${url}" '
        .placementState = "external"
        | .pbsUrl = $u
        | del(.placement)
    ' "$f" >"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Echo the active tankc storage id on <node> ($1) in <zone> ($2, default mgmt),
# or empty. Unreachable node / no pvesm ⇒ empty (never fails — discovery just
# moves on to the next node).
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

# Where a LEGACY (pre-v0.3) PBS actually runs, for the §4.1 backfill. Order:
#   1. .node — the old resolved-node write-back, when the config still has it
#   2. the cluster node whose configured .storage pool is active (an exact-name
#      probe, so a second node with an unrelated tankc can never win)
#   3. the first mgmt node
# Never moves anything: this only NAMES the node so the state can record it.
# Args: [zone]
pbs_legacy_pbs_node() {
    local zone="${1:-mgmt}" node storage out
    node="$(jq -r '.node // empty' "$(_pbs_backup_json)" 2>/dev/null || true)"
    [[ -n "${node}" ]] && { printf '%s\n' "${node}"; return 0; }
    storage="$(jq -r '.storage // empty' "$(_pbs_backup_json)" 2>/dev/null || true)"
    if [[ -n "${storage}" ]]; then
        while IFS= read -r node; do
            [[ -n "${node}" ]] || continue
            out="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                "root@${node}.${zone}.internal" "pvesm status" 2>/dev/null)" || continue
            _pbs_storage_active "${out}" "${storage}" && { printf '%s\n' "${node}"; return 0; }
        done < <(pbs_cluster_nodes "$(get_node_hostname 0)" "${zone}")
    fi
    get_node_hostname 0
}

# Emit "<state>[ <storage>]" — no trailing space when there is no storage, so
# the line is exactly what a caller's `read -r MODE STORAGE` expects either way.
_pbs_emit_state() {
    if [[ -n "${2:-}" ]]; then printf '%s %s\n' "$1" "$2"; else printf '%s\n' "$1"; fi
}

# Resolve the placement state per §2.2. Echoes ONE line on stdout (diagnostics
# stay off stdout so callers can parse it):
#   "node:<name> <storage>"  → realize/keep PBS on <name>'s <storage>
#   "shim"                   → no datastore anywhere
#   "external"               → consume the PBS at .pbsUrl; provision nothing
# Args: <current-state> <constraint-node|""> <zone> [fallback-node]
pbs_resolve_placement_state() {
    local state="$1" constraint="$2" zone="${3:-mgmt}" fallback="${4:-}" pinned store node

    # 1./2. a concrete state is kept — external is sticky, node:<name> idempotent.
    [[ "${state}" == "external" ]] && { printf 'external\n'; return 0; }
    if pinned="$(pbs_state_node "${state}")"; then
        # Re-probe the pool so a renamed/replaced pool is picked up, but keep
        # the state either way — the node is what was decided, not re-decided.
        store="$(pbs_probe_tankc "${pinned}" "${zone}")"
        _pbs_emit_state "node:${pinned}" "${store}"
        return 0
    fi

    # 3. empty or shim → derive. A .node constraint restricts discovery to that
    #    ONE node (§2.1); unset searches the whole cluster.
    if [[ -n "${constraint}" ]]; then
        store="$(pbs_probe_tankc "${constraint}" "${zone}")"
        [[ -n "${store}" ]] && { _pbs_emit_state "node:${constraint}" "${store}"; return 0; }
        printf 'shim\n'; return 0
    fi
    while IFS= read -r node; do
        [[ -n "${node}" ]] || continue
        store="$(pbs_probe_tankc "${node}" "${zone}")"
        [[ -n "${store}" ]] && { _pbs_emit_state "node:${node}" "${store}"; return 0; }
    done < <(pbs_cluster_nodes "${fallback:-$(get_node_hostname 0)}" "${zone}")
    printf 'shim\n'
}

# Persist the resolved state into config/backup.json: .placementState=<state>
# and (for a local PBS) the resolved .storage. The resolved NODE is carried by
# the state itself (node:<name>); .node stays the operator's discovery
# constraint and is never overwritten here. Idempotent.
# Args: <state> [storage]
pbs_write_placement_state() {
    local state="$1" storage="${2:-}" f tmp
    f="$(_pbs_backup_json)"
    [[ -f "$f" ]] || { warn "pbs_write_placement_state: ${f} missing"; return 1; }
    tmp="$(mktemp)"
    jq --arg m "$state" --arg s "$storage" '
        .placementState = $m
        | (if $s != "" then .storage = $s else . end)
    ' "$f" >"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
