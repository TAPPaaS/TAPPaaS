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
# Requires: common-install-routines.sh (info/warn/error, get_node_hostname,
# colour vars, CONFIG_DIR) sourced first. PBS storage name honours #199.

PBS_JOB_MARKER="TAPPaaS-backup-vm-managed"
PBS_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# PBS datastore / Proxmox storage name (issue #199), default tappaas_backup.
pbs_storage_name() {
    jq -r '.pbsStorageName // "tappaas_backup"' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null || echo "tappaas_backup"
}

# Hostname of the node PBS is installed on (backup.json's `node`). The PBS
# datastore + services live here; fall back to the first mgmt node.
pbs_node() {
    local node
    node="$(jq -r '.node // empty' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null)"
    [[ -n "$node" ]] && printf '%s\n' "$node" || get_node_hostname 0
}

# Order proxmox-backup{,-proxy}.service After/Requires zfs-mount.service so PBS
# never opens the (ZFS-backed) chunk store before the datastore is mounted on
# boot (issue #230 — "unable to open chunk store - No such file or directory").
# Covers BOTH units (the proxy is the one that actually serves the datastore).
# Idempotent: only writes a drop-in / reloads when missing or stale. Runs on the
# PBS node itself. No `ssh -n` here — the remote heredoc needs stdin.
pbs_ensure_zfs_ordering() {
    local node
    node="$(pbs_node)"
    info "${BOLD}Ensuring PBS waits for ZFS mount on ${node} (issue #230)${CL}"
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" 'bash -s' <<'REMOTE'
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

# VMIDs from backup.json's alwaysBackup list (foundation VMs that bootstrap
# before the backup server and so cannot dependsOn backup:vm). Each entry is a
# module name resolved to its VMID via its deployed config. Space-separated.
pbs_always_vmids() {
    local name vmid
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        vmid=$(jq -r '.vmid // empty' "${PBS_CONFIG_DIR}/${name}.json" 2>/dev/null)
        [[ -n "$vmid" ]] && printf '%s\n' "$vmid"
    done < <(jq -r '.alwaysBackup // [] | .[]' "${PBS_CONFIG_DIR}/backup.json" 2>/dev/null)
}

# CSV of every VMID that should be backed up: modules that dependsOn backup:vm,
# plus backup.json's alwaysBackup set (sorted, unique).
pbs_declared_vmids() {
    local f vmid
    local -a out=()
    for f in "${PBS_CONFIG_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        jq -e '(.dependsOn // []) | index("backup:vm")' "$f" >/dev/null 2>&1 || continue
        vmid=$(jq -r '.vmid // empty' "$f" 2>/dev/null)
        [[ -n "$vmid" ]] && out+=("$vmid")
    done
    while IFS= read -r vmid; do [[ -n "$vmid" ]] && out+=("$vmid"); done < <(pbs_always_vmids)
    [[ ${#out[@]} -eq 0 ]] && return 0
    printf '%s\n' "${out[@]}" | sort -n -u | paste -sd',' -
}

# Ensure every alwaysBackup VMID is in the managed job. Called by the backup
# module's install/update so foundation VMs (firewall, tappaas-cicd) are
# registered once the backup server exists.
pbs_ensure_always() {
    local vmid
    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] || continue
        pbs_ensure_vmid "$vmid" || return 1
    done < <(pbs_always_vmids)
}

# UUID of the managed job (by marker comment); empty if none.
pbs_managed_job_id() {
    _pbs_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null \
        | jq -r --arg m "$PBS_JOB_MARKER" '.[] | select((.comment // "")==$m) | .id' 2>/dev/null | head -1
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

# Ensure <vmid> is in the managed backup job, creating the job if absent.
pbs_ensure_vmid() {
    local vmid="$1" id store cur newlist
    [[ -n "$vmid" ]] || { error "pbs_ensure_vmid: empty vmid"; return 1; }

    pbs_migrate_all_job || return 1
    id="$(pbs_managed_job_id)"

    if [[ -z "$id" ]]; then
        store="$(pbs_storage_name)"
        info "  Creating managed PBS backup job on '${store}' (vmid ${vmid}, daily 21:00)"
        _pbs_ssh "pvesh create /cluster/backup --storage '${store}' --vmid '${vmid}' --mode snapshot --compress zstd --starttime 21:00 --enabled 1 --mailnotification always --comment '${PBS_JOB_MARKER}'" >/dev/null \
            || { error "  Failed to create the managed backup job"; return 1; }
        return 0
    fi

    cur="$(pbs_job_vmids "$id")"
    if _pbs_csv_has "$cur" "$vmid"; then
        info "  ${GN}✓${CL} VMID ${vmid} already covered by the backup job"
        return 0
    fi
    newlist="$(_pbs_csv_add "$cur" "$vmid")"
    info "  Adding VMID ${vmid} to backup job → ${newlist}"
    _pbs_ssh "pvesh set /cluster/backup/${id} --vmid '${newlist}'" >/dev/null \
        || { error "  Failed to add VMID ${vmid} to the backup job"; return 1; }
}

# Remove <vmid> from the managed backup job; delete the job if it becomes empty.
pbs_remove_vmid() {
    local vmid="$1" id cur newlist
    [[ -n "$vmid" ]] || { error "pbs_remove_vmid: empty vmid"; return 1; }

    id="$(pbs_managed_job_id)"
    [[ -z "$id" ]] && { info "  No managed backup job — nothing to remove"; return 0; }

    cur="$(pbs_job_vmids "$id")"
    if ! _pbs_csv_has "$cur" "$vmid"; then
        info "  VMID ${vmid} not in the backup job — nothing to remove"
        return 0
    fi
    newlist="$(_pbs_csv_remove "$cur" "$vmid")"
    if [[ -z "$newlist" ]]; then
        info "  Removing VMID ${vmid} (last entry) → deleting the managed backup job"
        _pbs_ssh "pvesh delete /cluster/backup/${id}" >/dev/null \
            || { error "  Failed to delete the backup job"; return 1; }
    else
        info "  Removing VMID ${vmid} from backup job → ${newlist}"
        _pbs_ssh "pvesh set /cluster/backup/${id} --vmid '${newlist}'" >/dev/null \
            || { error "  Failed to update the backup job"; return 1; }
    fi
}
