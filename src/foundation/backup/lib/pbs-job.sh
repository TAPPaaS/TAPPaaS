# shellcheck shell=bash
# pbs-job.sh — manage the single shared TAPPaaS PBS backup job (issue #200).
#
# Sourced (.) by backup/services/vm/{install,update,delete}-service.sh. The
# backup:vm service is dependsOn-driven: only modules that declare
# "dependsOn": ["backup:vm"] are backed up. They are all collected into ONE
# cluster backup job (identified by a marker comment) whose --vmid list this
# library maintains — install/update add the VM, delete removes it. A legacy
# `--all` job (the original "back up everything" model) is migrated in place
# the first time a backup:vm module is installed/updated.
#
# Requires: common-install-routines.sh (info/warn/error/debug, get_node_hostname,
# colour vars, CONFIG_DIR) sourced first. PBS storage name honours #199.

PBS_JOB_MARKER="TAPPaaS-backup-vm-managed"
PBS_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# Schedule buckets (ADR-012 §3.2/D16) live in pbs-schedule.sh; this library owns
# the jobs, that one owns which job a module belongs in. Source it here so every
# existing caller of pbs-job.sh gets bucket support without changing its sourcing.
if ! declare -F pbs_bucket_marker >/dev/null 2>&1; then
    # shellcheck source=pbs-schedule.sh disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/pbs-schedule.sh"
fi

# PBS datastore / Proxmox storage name (issue #199), default tappaas_backup.
pbs_storage_name() {
    jq -r '.pbsStorageName // "tappaas_backup"' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null || echo "tappaas_backup"
}

# The Host PBS runs on (#457, ADR-012 §2.1): `placementState: node` + `.node`
# (or the pre-#600 `node:<name>`); a legacy `local` falls back to `.node`. With
# no Host recorded it FAILS, naming why — it used to fall back to the cluster's
# first node, an address with no reference to where PBS actually runs.
pbs_node() {
    local state node
    state="$(jq -r '.placementState // empty' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null)"
    case "${state}" in
        node:?*) printf '%s\n' "${state#node:}"; return 0 ;;   # pre-#600 form
    esac
    node="$(jq -r '.node // empty' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null)"
    if [[ -n "${node}" ]]; then printf '%s\n' "${node}"; return 0; fi
    error "No PBS Host recorded (placementState '${state:-empty}', no .node) — nothing to connect to; run: module-manager module update backup" >&2
    return 1
}

# How to reach the PBS Host <node> — every ssh to the PBS goes through this, so
# the backup module has one address for its PBS (#457). A `kind: machine`
# instance is reached by its recorded `address` (it may have no DNS name); a
# cluster node by <node>.mgmt.internal. The same rule as pbs_host_addr (#601).
pbs_node_addr() {
    local node="$1" addr
    # Already a DNS name or an address (`backup-controller --pbs <host>`): as is.
    [[ "${node}" == *.* ]] && { printf '%s\n' "${node}"; return 0; }
    addr="$(jq -r 'if type == "object" and (.kind // "") == "machine" then (.address // "") else "" end' \
        "${PBS_CONFIG_DIR}/${node}.json" 2>/dev/null || true)"
    printf '%s\n' "${addr:-${node}.mgmt.internal}"
}

# Order proxmox-backup{,-proxy}.service After/Requires zfs-mount.service so PBS
# never opens the (ZFS-backed) chunk store before the datastore is mounted on
# boot (issue #230 — "unable to open chunk store - No such file or directory").
# Covers BOTH units (the proxy is the one that actually serves the datastore).
# Idempotent: only writes a drop-in / reloads when missing or stale. Runs on the
# PBS node itself. No `ssh -n` here — the remote heredoc needs stdin.
pbs_ensure_zfs_ordering() {
    local node _out _rc _l
    node="$(pbs_node)"
    info "${BOLD}Ensuring PBS waits for ZFS mount on ${node} (issue #230)${CL}"
    # Route the remote script's per-unit output to [Debug]; surface it on failure.
    _out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@$(pbs_node_addr "${node}")" 'bash -s' 2>&1 <<'REMOTE'
set -euo pipefail
want='[Unit]
After=zfs-mount.service
Requires=zfs-mount.service'
changed=0
for unit in proxmox-backup.service proxmox-backup-proxy.service; do
    dir="/etc/systemd/system/${unit}.d"
    conf="${dir}/zfs-wait.conf"
    if [[ -f "$conf" ]] && [[ "$(cat "$conf")" == "$want" ]]; then
        echo "  ${conf} already current"
        continue
    fi
    mkdir -p "$dir"
    printf '%s\n' "$want" > "$conf"
    echo "  wrote ${conf}"
    changed=1
done
if [[ "$changed" -eq 1 ]]; then
    systemctl daemon-reload
    echo "  systemctl daemon-reload done"
fi
REMOTE
)" && _rc=0 || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        # Loud, with the output: the 2026-08-17 nightly died here in silence
        # (#457) — ssh to a stale host, the error only ever at [Debug].
        error "Could not reach the PBS host ${node} ($(pbs_node_addr "${node}")) to check its ZFS ordering (rc ${_rc}):"
        [ -n "$_out" ] && printf '%s\n' "$_out" | sed 's/^/    /' >&2
    elif [ -n "$_out" ]; then while IFS= read -r _l; do debug "  $_l"; done <<<"$_out"; fi
    return "$_rc"
}

# Ensure the datastore has integrity checking configured (issue #228): a daily
# verify-job and verify-new. Without these, silent ZFS bit-rot in the chunk
# store goes undetected until a restore fails. The verify-job re-verifies a
# backup only when its last verification is older than 30 days
# (--ignore-verified true + --outdated-after 30), so the nightly 04:00 run
# spreads load instead of rescanning the whole datastore every night; verify-new
# checks each backup as it arrives. Runs on the PBS node; idempotent.
pbs_ensure_verify() {
    local node store
    node="$(pbs_node)"
    store="$(pbs_storage_name)"
    info "${BOLD}Ensuring PBS datastore verification on ${node} (issue #228)${CL}"
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@$(pbs_node_addr "${node}")" "bash -s -- '${store}'" <<'REMOTE'
set -euo pipefail
store="$1"
job="verify-${store}"
# Verify-job — daily at 04:00 (after GC at 03:00, before business hours).
if proxmox-backup-manager verify-job list 2>/dev/null | grep -q "${job}"; then
    echo "  verify-job ${job} already exists"
else
    proxmox-backup-manager verify-job create "${job}" \
        --store "${store}" \
        --schedule '04:00' \
        --ignore-verified true \
        --outdated-after 30
    echo "  created verify-job ${job} (daily 04:00, re-verify backups older than 30 days)"
fi
# Auto-verify each new backup on arrival (idempotent — just sets the flag).
proxmox-backup-manager datastore update "${store}" --verify-new true
echo "  verify-new enabled on ${store}"
REMOTE
}

# Run a command on a reachable mgmt node (where pvesh talks to the cluster).
# -n (stdin from /dev/null) is essential: these run inside `while read` loops,
# and without it ssh would swallow the loop's remaining input.
_pbs_ssh() {
    local node
    node="$(get_node_hostname 0)"
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" "$@"
}

# ── Pure CSV helpers (no cluster access — unit-testable) ─────────────

# Is <vmid> ($2) present in the CSV list <csv> ($1)? Returns 0/1.
_pbs_csv_has() {
    case ",${1}," in *",${2},"*) return 0 ;; *) return 1 ;; esac
}

# Add <vmid> to CSV <csv>; print the deduplicated, numerically-sorted result.
_pbs_csv_add() {
    printf '%s\n%s\n' "${1//,/$'\n'}" "${2}" | sed '/^$/d' | sort -n -u | paste -sd',' -
}

# Remove <vmid> from CSV <csv>; print the result (may be empty).
_pbs_csv_remove() {
    printf '%s\n' "${1//,/$'\n'}" | sed '/^$/d' | grep -vx "${2}" | sort -n -u | paste -sd',' -
}

# ── Cluster queries ──────────────────────────────────────────────────

# True when <config-file> is an ARCHIVED module (#627). `module-manager module
# delete --archive` removes the VM but keeps the config, its PBS snapshots, and
# its backup:vm declaration — deliberately, so a restore re-wires itself. The
# declaration therefore outlives the guest, and a set operation that trusts it
# re-adds a VMID that no longer exists: vzdump then errors on a missing guest,
# the failure delete-service.sh (#200) removes it to prevent. Read the status,
# not just the relationship.
_pbs_is_archived() {
    jq -e '.status == "archived"' "$1" >/dev/null 2>&1
}


# DEPRECATED (ADR-012 §2.7, D18) — VMIDs from backup.json's alwaysBackup list.
# Superseded by `integratesWith: ["backup:vm"]`, which #501 made possible: a
# foundation VM that bootstraps before the backup server declares the
# integration instead of being named in a central list. Read for one release so
# an un-migrated deployment keeps its coverage; then this and the field go.
#
# An entry that resolves to no deployed config is WARNED about, not skipped in
# silence — and emphatically not with `[[ -n "$vmid" ]] && printf`, whose false
# branch returns 1 and, under the `set -e` every caller runs with, killed the
# whole loop inside its process substitution. That is not hypothetical: the
# stale entry `firewall` (no config/firewall.json) silently truncated the list
# before `tappaas-cicd`, so the mothership was never in the backup job at all
# while the list claimed it was. Found live, 2026-09-09.
pbs_always_vmids() {
    local name vmid
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if _pbs_is_archived "${PBS_CONFIG_DIR}/${name}.json"; then continue; fi
        vmid=$(jq -r '.vmid // empty' "${PBS_CONFIG_DIR}/${name}.json" 2>/dev/null || true)
        if [[ -n "$vmid" ]]; then
            printf '%s\n' "$vmid"
        else
            warn "  alwaysBackup entry '${name}' has no deployed config/vmid — skipping it (deprecated field: declare integratesWith [\"backup:vm\"] on the module instead)" >&2
        fi
    done < <(jq -r '.alwaysBackup // [] | .[]' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null || true)
}

# Every deployed module that has opted into VM backup, by EITHER relationship:
#   dependsOn      backup:vm   a hard dependency — install ordering enforced
#   integratesWith backup:vm   an optional integration (#501) — no ordering, so
#                              the foundation VMs that come up before the backup
#                              server can still ask to be backed up (D18)
# Backup stays opt-in: a module declaring neither is in no job. An ARCHIVED
# module is out regardless: it keeps the declaration for restore but has no
# guest (#627). Echoes VMIDs.
pbs_optin_vmids() {
    local f vmid
    for f in "${PBS_CONFIG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        jq -e '((.dependsOn // []) + (.integratesWith // [])) | index("backup:vm")' \
            "$f" >/dev/null 2>&1 || continue
        # An archived module keeps the declaration but has no guest (#627).
        # `if`, not `&& continue`: a false `&&` list as the last statement in
        # the loop body is what truncated pbs_always_vmids under `set -e`.
        if _pbs_is_archived "$f"; then continue; fi
        vmid=$(jq -r '.vmid // empty' "$f" 2>/dev/null || true)
        [[ -n "$vmid" ]] && printf '%s\n' "$vmid"
    done
    return 0
}

# CSV of every VMID that should be backed up: everything that opted in through
# dependsOn/integratesWith backup:vm, plus the deprecated alwaysBackup set while
# it is still read (sorted, unique).
pbs_declared_vmids() {
    local vmid
    local -a out=()
    while IFS= read -r vmid; do [[ -n "$vmid" ]] && out+=("$vmid"); done < <(pbs_optin_vmids)
    while IFS= read -r vmid; do [[ -n "$vmid" ]] && out+=("$vmid"); done < <(pbs_always_vmids)
    [[ ${#out[@]} -eq 0 ]] && return 0
    printf '%s\n' "${out[@]}" | sort -n -u | paste -sd',' -
}

# Ensure every opted-in VMID is in the managed job — the backup module's own
# membership reconcile, run by its install/update. This is what closes the
# bootstrap gap: a module that declared `integratesWith: backup:vm` before the
# backup server existed is picked up here, once it does (#501 install-module
# wires the reverse direction when the provider arrives; this heals the rest).
# Deliberately a SET operation, never a truncating loop: one unresolvable entry
# must not cost the others their backup. Because it never removes, its INPUT is
# what has to be right — an archived module left in the opt-in set is re-added
# here every update (#627), which is why pbs_optin_vmids reads the status.
pbs_ensure_declared() {
    local vmid rc=0
    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] || continue
        pbs_ensure_vmid "$vmid" || rc=1
    done < <({ pbs_optin_vmids; pbs_always_vmids; } | sort -n -u)
    return "${rc}"
}

# Deprecated name kept for one release: callers outside this module may still
# use it. Same reconcile, wider set.
pbs_ensure_always() { pbs_ensure_declared; }

# UUID of a managed job by marker comment (default: the daily bucket's marker,
# which is the original one — ADR-012 D16). Empty if that job does not exist.
pbs_managed_job_id() {
    local marker="${1:-$PBS_JOB_MARKER}"
    _pbs_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null \
        | jq -r --arg m "$marker" '.[] | select((.comment // "")==$m) | .id' 2>/dev/null | head -1
}

# UUID of a legacy --all job on our storage that is NOT the managed one; empty if none.
pbs_legacy_all_job_id() {
    local store; store="$(pbs_storage_name)"
    _pbs_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null \
        | jq -r --arg s "$store" --arg m "$PBS_JOB_MARKER" \
            '.[] | select(.storage==$s and (.all==1) and ((.comment // "")!=$m)) | .id' 2>/dev/null | head -1
}

# Current --vmid CSV of job <id>.
pbs_job_vmids() {
    _pbs_ssh "pvesh get /cluster/backup/$1 --output-format json" 2>/dev/null | jq -r '.vmid // ""' 2>/dev/null
}

# JSON array of the managed BUCKET jobs that exist, membership included:
#   [{"bucket":"daily","jobId":"...","vmids":["110","130"]}, ...]
#
# Membership is a per-bucket question, and asking it one bucket at a time was
# the trap #627 fell into: `pbs_managed_job_id` defaults to the DAILY marker,
# so "is this VMID in the backup job?" answered from it reads `false` for a
# weekly- or monthly-scheduled guest that is backed up perfectly well. Any
# coverage answer has to be the union over all three (ADR-012 D16).
#
# ONE pvesh call for all three buckets: coverage is asked often enough that
# three ssh round trips to answer it is three times the latency, and the
# markers are all derivable from the same /cluster/backup listing.
# Prints `[]` (not an error) when the cluster is unreachable — the caller
# decides what an unknown job list means.
pbs_bucket_jobs_json() {
    local json
    json="$(_pbs_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null || true)"
    [[ -n "$json" ]] || { printf '[]\n'; return 0; }
    printf '%s' "$json" | jq -c --arg d "$PBS_JOB_MARKER" '
        [ {daily: $d, weekly: "\($d)-weekly", monthly: "\($d)-monthly"} | to_entries[] ] as $b
        | [ $b[] as $e
            | ( [ .[] | select((.comment // "") == $e.value) ][0] // empty )
            | { bucket: $e.key, jobId: .id,
                vmids: ((.vmid // "") | split(",") | map(select(length > 0))) } ]
    ' 2>/dev/null || printf '[]\n'
}

# ── Mutations ────────────────────────────────────────────────────────

# Convert a legacy --all job into the managed job in place, seeded with every
# currently-declared backup:vm VMID. Idempotent (no-op when none exists).
pbs_migrate_all_job() {
    local legacy seed
    legacy="$(pbs_legacy_all_job_id)"
    [[ -z "$legacy" ]] && return 0
    seed="$(pbs_declared_vmids)"
    if [[ -z "$seed" ]]; then
        warn "  Legacy --all backup job present but no backup:vm modules deployed — leaving it as-is"
        return 0
    fi
    info "  Migrating legacy '--all' backup job → managed vmid list (${seed})"
    _pbs_ssh "pvesh set /cluster/backup/${legacy} --vmid '${seed}' --delete all --comment '${PBS_JOB_MARKER}'" >/dev/null \
        || { error "  Failed to migrate the --all backup job"; return 1; }
}

# Ensure <vmid> is in the backup job of <bucket> (default daily), creating that
# job if it does not exist yet. Creating a bucket job is what makes a per-module
# schedule real — Proxmox schedules a JOB, not a guest (ADR-012 D16).
pbs_ensure_vmid() {
    local vmid="$1" bucket="${2:-daily}" id store cur newlist marker cal
    [[ -n "$vmid" ]] || { error "pbs_ensure_vmid: empty vmid"; return 1; }
    marker="$(pbs_bucket_marker "$bucket")" || { error "pbs_ensure_vmid: unknown bucket '$bucket'"; return 1; }

    pbs_migrate_all_job || return 1
    id="$(pbs_managed_job_id "$marker")"

    if [[ -z "$id" ]]; then
        store="$(pbs_storage_name)"
        cal="$(pbs_schedule_calendar "$bucket")"
        info "  Creating managed PBS backup job on '${store}' (vmid ${vmid}, ${bucket} '${cal}')"
        _pbs_ssh "pvesh create /cluster/backup --storage '${store}' --vmid '${vmid}' --mode snapshot --compress zstd --schedule '${cal}' --enabled 1 --mailnotification always --comment '${marker}'" >/dev/null \
            || { error "  Failed to create the ${bucket} backup job"; return 1; }
        return 0
    fi

    cur="$(pbs_job_vmids "$id")"
    if _pbs_csv_has "$cur" "$vmid"; then
        # debug, not info: this is the idempotent no-op case and it prints once
        # per VM on every sweep. The events worth reading are the other two —
        # a VM being ADDED to the job, or the job being created — and a module
        # that silently lost coverage shows up as an "Adding" line next sweep.
        debug "  ${GN}✓${CL} VMID ${vmid} already covered by the ${bucket} backup job"
        return 0
    fi
    newlist="$(_pbs_csv_add "$cur" "$vmid")"
    info "  Adding VMID ${vmid} to the ${bucket} backup job → ${newlist}"
    _pbs_ssh "pvesh set /cluster/backup/${id} --vmid '${newlist}'" >/dev/null \
        || { error "  Failed to add VMID ${vmid} to the ${bucket} backup job"; return 1; }
}

# Place <vmid> in exactly one bucket: add it to <bucket> and remove it from
# every other. A schedule change is a MOVE, never a second membership — a guest
# in two jobs would be backed up twice on the days they coincide.
pbs_place_vmid() {
    local vmid="$1" bucket="${2:-daily}" b
    pbs_ensure_vmid "$vmid" "$bucket" || return 1
    while IFS= read -r b; do
        [[ "$b" == "$bucket" ]] && continue
        pbs_remove_vmid "$vmid" "$b" quiet || return 1
    done < <(pbs_buckets)
}

# Remove <vmid> from <bucket>'s backup job (default daily); delete that job if
# it becomes empty. A third argument of "quiet" suppresses the not-present
# chatter, for the sweep pbs_place_vmid does over the other buckets.
pbs_remove_vmid() {
    local vmid="$1" bucket="${2:-daily}" quiet="${3:-}" id cur newlist marker
    [[ -n "$vmid" ]] || { error "pbs_remove_vmid: empty vmid"; return 1; }
    marker="$(pbs_bucket_marker "$bucket")" || { error "pbs_remove_vmid: unknown bucket '$bucket'"; return 1; }

    id="$(pbs_managed_job_id "$marker")"
    [[ -z "$id" ]] && { [[ "$quiet" == "quiet" ]] || info "  No ${bucket} backup job — nothing to remove"; return 0; }

    cur="$(pbs_job_vmids "$id")"
    if ! _pbs_csv_has "$cur" "$vmid"; then
        [[ "$quiet" == "quiet" ]] || info "  VMID ${vmid} not in the ${bucket} backup job — nothing to remove"
        return 0
    fi
    newlist="$(_pbs_csv_remove "$cur" "$vmid")"
    if [[ -z "$newlist" ]]; then
        info "  Removing VMID ${vmid} (last entry) → deleting the ${bucket} backup job"
        _pbs_ssh "pvesh delete /cluster/backup/${id}" >/dev/null \
            || { error "  Failed to delete the backup job"; return 1; }
    else
        info "  Removing VMID ${vmid} from the ${bucket} backup job → ${newlist}"
        _pbs_ssh "pvesh set /cluster/backup/${id} --vmid '${newlist}'" >/dev/null \
            || { error "  Failed to update the backup job"; return 1; }
    fi
}
