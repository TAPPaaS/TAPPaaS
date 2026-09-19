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
#                  provisioned. Set at install time and sticky thereafter:
#                  left only by `backup-manager placement reset` (#607).
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
#   module-manager module modify backup --set placementState=external --set pbsUrl=<url>
#
# Two operator inputs shape resolution, both on backup.json:
#   .node    optional — restrict tankc discovery to ONE named node ("" = all)
#   .pbsUrl  the PBS clients push to (default backup.mgmt.internal)
#
# The RESOLVED node is stored as ADR-012 §2.1 decides (#600): `placementState:
# "node"` with `.node` naming the Host — a cluster node or a `kind: machine`
# instance. Before resolution `.node` is the operator's discovery constraint;
# after it, the Host. The 3-way merge keeps it: a resolved `.node` differs from
# the release's empty default, so it reads as set here, never as a release value.
# (The pre-#600 form `node:<name>` in the state is read until migration 0007.)
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

# jq: the placement state in its internal form. On disk the state is
# `placementState: "node"` with `.node` naming the Host (ADR-012 §2.1, #600);
# inside these scripts it is `node:<host>`, which is also the pre-#600 on-disk
# form, still read until migration 0007 has run. `node` with no `.node` is a
# state that names nothing, and reads as unresolved.
PBS_JQ_STATE='if .placementState == "node" then (if (.node // "") != "" then "node:" + .node else "" end) else (.placementState // "") end'

# Resolved placement state recorded in config; empty if unset.
pbs_placement_state() {
    local f; f="$(_pbs_backup_json "${1:-}")"
    jq -r "${PBS_JQ_STATE}" "$f" 2>/dev/null || true
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
    state="$(jq -r "${PBS_JQ_STATE}" "$f" 2>/dev/null || true)"
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
    # A resolved node is stored as §2.1 says: placementState "node" + .node.
    jq --arg s "${new}" --arg h "${host:-}" '
        del(.placement)
        | (if ($s | startswith("node:")) then .placementState = "node" | .node = ($s | ltrimstr("node:"))
           elif $s != "" then .placementState = $s else . end)
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

# ── A PBS that already serves this Site (§2.2 rule 3, #602) ──────────
#
# An empty placementState must never be a licence to provision over a PBS that
# already runs. On a PVE node the pool probe (`pvesm status`) is one way to see
# a datastore; on any other Host (§1.3) it sees nothing — which is how a second
# PBS would be installed beside the real one. So before any discovery, ask the
# candidate Hosts themselves.

# Does <host> ($1, in <zone> $2) run a PBS holding datastore <name> ($3)?
# Asked over the Host's own key with proxmox-backup-manager — authoritative for
# "holds the datastore", which a bare :8007 answer is not. Echoes
#   yes <hostname> | no | unreachable
# (no = reachable, but no PBS or not that datastore). <hostname> is the Host's
# OWN short name, because the name it was reached by may be an alias:
# backup.mgmt.internal is typically a DNS alias for the node PBS runs on, and
# recording "backup" would name a Host that does not exist.
pbs_probe_serving() {
    local host="$1" zone="${2:-mgmt}" store="$3" out rc name
    out="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${host}.${zone}.internal" \
        "command -v proxmox-backup-manager >/dev/null 2>&1 || exit 3; hostname -s; proxmox-backup-manager datastore list --output-format json" 2>/dev/null)"
    rc=$?
    case ${rc} in
        0) name="$(head -n1 <<<"${out}")"
           tail -n +2 <<<"${out}" | jq -e --arg s "${store}" 'any(.[]?; .name == $s)' >/dev/null 2>&1 \
               && echo "yes ${name:-${host}}" || echo no ;;
        3) echo no ;;
        *) echo unreachable ;;
    esac
}

# Does anything answer as a PBS web service on https://<name>:8007? Used only to
# tell "a PBS we cannot reach by key" from "no PBS at all". Echoes yes | no.
pbs_port_answers() {
    local code
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "https://$1:8007/" 2>/dev/null || true)"
    [[ -n "${code}" && "${code}" != "000" ]] && echo yes || echo no
}

# The Host already serving this Site's datastore, if any. Candidates, in order:
# the `node` Host (the operator's constraint / the recorded Host), the host
# behind pbsUrl, then every cluster member. Echoes ONE line:
#   <host>                a managed Host holds the datastore → adopt it
#   unmanaged <pbsUrl>    pbsUrl answers as a PBS but no Host we manage holds it
#                         — that is `external`, which must be forced (rule 1)
# rc 1 when nothing serves (discovery may proceed).
# Args: <constraint-node|""> <zone> [fallback-node]
pbs_find_serving_pbs() {
    local constraint="$1" zone="${2:-mgmt}" fallback="${3:-}" store url urlhost seen=" " h
    store="$(jq -r '.pbsStorageName // "tappaas_backup"' "$(_pbs_backup_json)" 2>/dev/null || echo tappaas_backup)"
    url="$(pbs_pbs_url)"
    # pbsUrl is a DNS name like backup.mgmt.internal: its first label is the Host
    # when it lives in this zone; anything else is not a Host we can name.
    urlhost=""
    [[ "${url}" == *".${zone}.internal" ]] && urlhost="${url%%.*}"
    local ans
    while IFS= read -r h; do
        [[ -n "${h}" && "${seen}" != *" ${h} "* ]] || continue
        seen+="${h} "
        ans="$(pbs_probe_serving "${h}" "${zone}" "${store}")"
        # The Host's own name, not the alias it was reached by.
        [[ "${ans}" == yes\ * ]] && { printf '%s\n' "${ans#yes }"; return 0; }
    done < <(printf '%s\n' "${constraint}" "${urlhost}"; pbs_cluster_nodes "${fallback:-$(get_node_hostname 0)}" "${zone}")
    [[ "$(pbs_port_answers "${url}")" == yes ]] && { printf 'unmanaged %s\n' "${url}"; return 0; }
    return 1
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
#   "unmanaged <url>"        → a PBS already answers at <url> on a host this Site
#                              does not manage: stop — external is forced, not inferred
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

    # 3. empty → first adopt a PBS that already serves this Site (#602). Never
    #    provision over one: an unmanaged one stops resolution ("unmanaged
    #    <url>" — force external, rule 1).
    local serving
    if [[ -z "${state}" ]] && serving="$(pbs_find_serving_pbs "${constraint}" "${zone}" "${fallback}")"; then
        if [[ "${serving}" == unmanaged\ * ]]; then printf '%s
' "${serving}"; return 0; fi
        store="$(pbs_probe_tankc "${serving}" "${zone}")"
        _pbs_emit_state "node:${serving}" "${store}"
        return 0
    fi

    # 4. still empty (nothing serves) or shim → derive. A .node constraint
    #    restricts discovery to that ONE node (§2.1); unset searches the cluster.
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

# Persist the resolved state into config/backup.json (§2.1, #600): an internal
# `node:<host>` is written as .placementState="node" + .node=<host>; shim and
# external as themselves (.node untouched — it is still a discovery constraint
# for a shim). For a local PBS the resolved .storage too. Idempotent.
# Args: <state> [storage]
pbs_write_placement_state() {
    local state="$1" storage="${2:-}" f tmp
    f="$(_pbs_backup_json)"
    [[ -f "$f" ]] || { warn "pbs_write_placement_state: ${f} missing"; return 1; }
    tmp="$(mktemp)"
    jq --arg m "$state" --arg s "$storage" '
        (if ($m | startswith("node:")) then .placementState = "node" | .node = ($m | ltrimstr("node:"))
         else .placementState = $m end)
        | (if $s != "" then .storage = $s else . end)
    ' "$f" >"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
