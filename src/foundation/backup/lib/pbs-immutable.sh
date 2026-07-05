# shellcheck shell=bash
# pbs-immutable.sh — optional WORM-ish ZFS-snapshot immutability for a PBS
# datastore (ADR-012 §3.5 / ADR-010 §7.3, #389 "no way to compromise the remote").
#
# The WEAKER of the two immutability tiers: periodic read-only ZFS snapshots of
# the datastore dataset, pruned to a retention. History cannot be rewritten by a
# sync/push credential holder (a buddy or client with write-no-delete) nor by
# PBS prune/GC — only by node-local root. S3 Object Lock (the ADR-010 satellite
# backend) is the STRONGER tier that survives even a full node-root compromise;
# it is provisioned satellite-side and is out of this module's scope.
#
# Opt-in via backup.json .immutableSnapshots { enabled, schedule, keep }.
# Installs a tiny snapshot+prune script + a systemd timer on the PBS node.
#
# Requires: common routines (info/warn/debug, colours) and pbs-job.sh
# (pbs_node, pbs_storage_name) sourced first.

SVC="tappaas-pbs-immutable"

# ── Pure helpers (unit-testable) ─────────────────────────────────────

# ZFS dataset from a datastore path: /tankc1/tappaas_backup → tankc1/tappaas_backup.
_pbs_dataset_from_path() { printf '%s\n' "${1#/}"; }

# systemd OnCalendar value from a friendly schedule word (or pass through a raw
# OnCalendar expression). hourly/daily/weekly → canonical calendar strings.
_pbs_immutable_oncalendar() {
    case "$1" in
        hourly) printf 'hourly\n' ;;
        daily)  printf 'daily\n' ;;
        weekly) printf 'weekly\n' ;;
        *)      printf '%s\n' "$1" ;;   # already an OnCalendar expression
    esac
}

# ── Node op (PBS host) ───────────────────────────────────────────────

# Install/refresh the snapshot script + systemd timer on the PBS node. Idempotent.
# Args: dataset schedule keep
pbs_immutable_ensure() {
    local dataset="$1" schedule="$2" keep="$3" node oncal
    node="$(pbs_node)"
    oncal="$(_pbs_immutable_oncalendar "$schedule")"
    info "${BOLD}Ensuring immutable ZFS snapshots on ${node} for ${BL}${dataset}${CL} (${oncal}, keep ${keep})${CL}"
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" "bash -s -- '${dataset}' '${keep}' '${oncal}' '${SVC}'" <<'REMOTE'
set -euo pipefail
dataset="$1"; keep="$2"; oncal="$3"; svc="$4"
install -d /usr/local/sbin
cat >/usr/local/sbin/${svc}.sh <<EOS
#!/usr/bin/env bash
# TAPPaaS immutable PBS datastore snapshots (ADR-012 §3.5). Managed — do not edit.
set -euo pipefail
dataset="\$1"; keep="\$2"
ts="\$(date +%Y%m%d-%H%M%S)"
zfs snapshot "\${dataset}@immutable-\${ts}"
# Keep only the newest \$keep immutable- snapshots (oldest pruned).
mapfile -t old < <(zfs list -H -t snapshot -o name -s creation 2>/dev/null | grep -F "\${dataset}@immutable-" | head -n "-\${keep}")
for s in "\${old[@]}"; do [ -n "\$s" ] && zfs destroy "\$s"; done
EOS
chmod 0755 /usr/local/sbin/${svc}.sh
cat >/etc/systemd/system/${svc}.service <<EOS
[Unit]
Description=TAPPaaS immutable PBS datastore ZFS snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/${svc}.sh ${dataset} ${keep}
EOS
cat >/etc/systemd/system/${svc}.timer <<EOS
[Unit]
Description=TAPPaaS immutable PBS datastore snapshot timer
[Timer]
OnCalendar=${oncal}
Persistent=true
[Install]
WantedBy=timers.target
EOS
systemctl daemon-reload
systemctl enable --now ${svc}.timer >/dev/null 2>&1
echo "  immutable snapshot timer active (${oncal}, keep ${keep}) on ${dataset}"
REMOTE
}

# Remove the immutable-snapshot timer/script (does NOT destroy existing snapshots).
pbs_immutable_disable() {
    local node; node="$(pbs_node)"
    ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.mgmt.internal" "bash -s -- '${SVC}'" <<'REMOTE'
set -uo pipefail
svc="$1"
systemctl disable --now "${svc}.timer" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${svc}.timer" "/etc/systemd/system/${svc}.service" "/usr/local/sbin/${svc}.sh"
systemctl daemon-reload || true
echo "  immutable snapshot timer removed (existing snapshots kept)"
REMOTE
}

# Read backup.json .immutableSnapshots and ensure/disable accordingly. Called by
# install.sh/update.sh once a local datastore exists. Args: storage datastore-name
pbs_immutable_from_config() {
    local storage="$1" ds="$2" cfg enabled schedule keep dataset
    cfg="${CONFIG_DIR:-/home/tappaas/config}/backup.json"
    enabled="$(jq -r '.immutableSnapshots.enabled // false' "$cfg" 2>/dev/null)"
    if [[ "$enabled" != "true" ]]; then
        debug "  immutable snapshots: disabled (.immutableSnapshots.enabled != true)"
        return 0
    fi
    schedule="$(jq -r '.immutableSnapshots.schedule // "daily"' "$cfg" 2>/dev/null)"
    keep="$(jq -r '.immutableSnapshots.keep // 30' "$cfg" 2>/dev/null)"
    dataset="$(_pbs_dataset_from_path "/${storage}/${ds}")"
    pbs_immutable_ensure "$dataset" "$schedule" "$keep"
}
