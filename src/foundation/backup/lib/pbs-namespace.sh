# shellcheck shell=bash
# pbs-namespace.sh — multi-source PBS datastore namespaces (issue #227).
#
# The single TAPPaaS PBS datastore holds, besides the local VM backups (root
# namespace, maintained by pbs-job.sh), isolated namespaces for other sources:
#   <store>/remote/<name>     a TAPPaaS buddy's backups   (Class A, pull model)
#   <store>/external/<name>   a third-party client        (Class B, push model)
#
# Namespace create/list/delete go through `proxmox-backup-debug api` on the PBS
# node: it talks to the local privileged API socket as root, so NO PBS
# credentials need to be stored. (proxmox-backup-manager has no `namespace`
# verb, and proxmox-backup-client demands a password even locally.) The create
# call is idempotent — re-creating an existing namespace returns success.
# ACL / remote / sync-job / prune use proxmox-backup-manager verbs (Phase 2/3).
#
# Requires: common-install-routines.sh (info/warn/error, colours) and
# pbs-job.sh (pbs_node, pbs_storage_name) sourced first.

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# ACL path for a namespace inside the datastore. Root ("") → /datastore/<store>;
# a namespace → /datastore/<store>/<ns> (e.g. /datastore/tappaas_backup/remote/lars).
_pbs_ns_acl_path() {
    local store="$1" ns="${2:-}"
    if [[ -z "$ns" ]]; then
        printf '/datastore/%s\n' "$store"
    else
        printf '/datastore/%s/%s\n' "$store" "$ns"
    fi
}

# Print the ancestor chain of a namespace, outermost first, so each level can be
# created before its child: "remote/lars" → "remote" then "remote/lars".
_pbs_ns_parents() {
    local ns="$1" acc="" part
    local IFS=/
    for part in $ns; do
        [[ -n "$part" ]] || continue
        acc="${acc:+$acc/}$part"
        printf '%s\n' "$acc"
    done
}

# Build `proxmox-backup-manager` prune `--keep-*` args from a retention JSON
# object with any of keepLast/keepDaily/keepWeekly/keepMonthly/keepYearly.
# Prints e.g. "--keep-last 4 --keep-daily 14" (empty string if none set).
_pbs_retention_args() {
    local json="$1" out="" pair key flag val
    for pair in keepLast:--keep-last keepDaily:--keep-daily keepWeekly:--keep-weekly \
                keepMonthly:--keep-monthly keepYearly:--keep-yearly; do
        key="${pair%%:*}"; flag="${pair##*:}"
        val="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$json" 2>/dev/null)"
        [[ -n "$val" ]] && out="${out:+$out }${flag} ${val}"
    done
    printf '%s\n' "$out"
}

# ── Node operations (PBS host, root-local via proxmox-backup-debug) ──

# Idempotently ensure namespace <ns> (and every ancestor) exists in the
# datastore. No-op for the root namespace.
pbs_ns_ensure() {
    local ns="$1" store node
    [[ -n "$ns" ]] || return 0
    store="$(pbs_storage_name)"
    node="$(pbs_node)"
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" "bash -s -- '${store}' '${ns}'" <<'REMOTE'
set -euo pipefail
store="$1"; ns="$2"
parent=""
IFS='/' read -ra parts <<<"$ns"
for name in "${parts[@]}"; do
    [[ -n "$name" ]] || continue
    # create is idempotent: re-creating an existing namespace succeeds.
    proxmox-backup-debug api create "/admin/datastore/${store}/namespace" \
        --name "$name" ${parent:+--parent "$parent"} --output-format json >/dev/null
    parent="${parent:+$parent/}$name"
done
echo "  namespace ${ns} ensured"
REMOTE
}

# Print the datastore's namespaces, one full path per line (root prints empty).
pbs_ns_list() {
    local store
    store="$(pbs_storage_name)"
    _pbs_node_run "proxmox-backup-debug api get /admin/datastore/${store}/namespace --output-format json" \
        2>/dev/null | jq -r '.[].ns'
}

# Delete namespace <ns>. Without --purge it only removes an empty namespace;
# with --purge it also deletes the backup groups inside it (destructive).
pbs_ns_delete() {
    local ns="$1" purge="${2:-}" store
    [[ -n "$ns" ]] || return 0   # never delete the root namespace
    store="$(pbs_storage_name)"
    local -a a=(proxmox-backup-debug api delete "/admin/datastore/${store}/namespace" --ns "$ns" --output-format json)
    [[ "$purge" == "--purge" ]] && a+=(--delete-groups true)
    _pbs_node_run "${a[@]}" >/dev/null
}

# ── PBS-node command runner (root-local; no stored credentials) ──────
#
# Builds a %q-quoted command line and runs it on the PBS node as root. Safe for
# values with spaces/specials (passwords, fingerprints). The remote shell
# re-parses the quoted line; stdout is returned for local piping to jq.
_pbs_node_run() {
    local node cmd
    node="$(pbs_node)"
    printf -v cmd '%q ' "$@"
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" "${cmd}"
}

# ── Class A: TAPPaaS buddy (pull model) ──────────────────────────────

_pbs_remote_exists() {
    _pbs_node_run proxmox-backup-manager remote list --output-format json 2>/dev/null \
        | jq -e --arg n "$1" 'any(.[]; .name==$n)' >/dev/null 2>&1
}

# Create/update the PBS `remote` entry for the buddy PBS we pull from.
# Args: name host auth-id password [fingerprint] [port]
pbs_remote_ensure() {
    local name="$1" host="$2" authid="$3" password="$4" fp="${5:-}" port="${6:-}"
    local verb=create
    _pbs_remote_exists "$name" && verb=update
    local -a a=(proxmox-backup-manager remote "$verb" "$name"
                --host "$host" --auth-id "$authid" --password "$password")
    [[ -n "$fp" ]] && a+=(--fingerprint "$fp")
    [[ -n "$port" ]] && a+=(--port "$port")
    _pbs_node_run "${a[@]}"
}

pbs_remote_delete() {
    _pbs_remote_exists "$1" || return 0
    _pbs_node_run proxmox-backup-manager remote remove "$1"
}

_pbs_syncjob_exists() {
    _pbs_node_run proxmox-backup-manager sync-job list --output-format json 2>/dev/null \
        | jq -e --arg i "$1" 'any(.[]; .id==$i)' >/dev/null 2>&1
}

# Create/update a pull sync-job into local namespace <ns>. On update only the
# mutable fields (schedule, remove-vanished) are touched to avoid identity churn.
# Args: id store ns remote remote-store remote-ns schedule remove-vanished
pbs_syncjob_ensure() {
    local id="$1" store="$2" ns="$3" remote="$4" rstore="$5" rns="$6" sched="$7" rv="$8"
    if _pbs_syncjob_exists "$id"; then
        local -a a=(proxmox-backup-manager sync-job update "$id" --remove-vanished "$rv")
        [[ -n "$sched" ]] && a+=(--schedule "$sched")
        _pbs_node_run "${a[@]}"
    else
        local -a a=(proxmox-backup-manager sync-job create "$id"
                    --store "$store" --ns "$ns" --remote "$remote"
                    --remote-store "$rstore" --remove-vanished "$rv")
        [[ -n "$rns" ]] && a+=(--remote-ns "$rns")
        [[ -n "$sched" ]] && a+=(--schedule "$sched")
        _pbs_node_run "${a[@]}"
    fi
}

pbs_syncjob_delete() {
    _pbs_syncjob_exists "$1" || return 0
    _pbs_node_run proxmox-backup-manager sync-job remove "$1"
}

_pbs_prunejob_exists() {
    _pbs_node_run proxmox-backup-manager prune-job list --output-format json 2>/dev/null \
        | jq -e --arg i "$1" 'any(.[]; .id==$i)' >/dev/null 2>&1
}

# Create/update a namespace-scoped prune-job. Retention args (--keep-*) are
# passed as already-split positional args after the schedule.
# Args: id store ns schedule [retention-args...]
pbs_prunejob_ensure_ns() {
    local id="$1" store="$2" ns="$3" sched="$4"; shift 4
    local verb=create
    _pbs_prunejob_exists "$id" && verb=update
    _pbs_node_run proxmox-backup-manager prune-job "$verb" "$id" \
        --store "$store" --ns "$ns" --schedule "$sched" "$@"
}

pbs_prunejob_delete() {
    _pbs_prunejob_exists "$1" || return 0
    _pbs_node_run proxmox-backup-manager prune-job remove "$1"
}

# ACL helpers (idempotent — acl update is set-semantics).
pbs_acl_ensure() {  # path role auth-id
    _pbs_node_run proxmox-backup-manager acl update "$1" "$2" --auth-id "$3"
}
pbs_acl_delete() {  # path role auth-id
    _pbs_node_run proxmox-backup-manager acl update "$1" "$2" --auth-id "$3" --delete 2>/dev/null || true
}

# ── Class B: external client (push model) ────────────────────────────

_pbs_user_exists() {
    _pbs_node_run proxmox-backup-manager user list --output-format json 2>/dev/null \
        | jq -e --arg u "$1" 'any(.[]; .userid==$u)' >/dev/null 2>&1
}

# Create the PBS user a third-party client authenticates as. Idempotent: skips
# if the user already exists (so a re-run never resets the client's password).
# Args: userid password
pbs_user_ensure() {
    local userid="$1" password="$2"
    _pbs_user_exists "$userid" && return 0
    _pbs_node_run proxmox-backup-manager user create "$userid" --password "$password"
}

pbs_user_delete() {
    _pbs_user_exists "$1" || return 0
    _pbs_node_run proxmox-backup-manager user remove "$1"
}
