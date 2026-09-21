# shellcheck shell=bash
# pbs-schedule.sh — the backup SCHEDULE cascade and its job buckets
# (ADR-012 §3.2, D16).
#
# A module's backup frequency resolves through Site → Environment → Module:
#
#   module.backup.schedule > environment.backup.schedule
#                          > site.backup.defaultSchedule > "daily"
#
# with a HARD CEILING: nothing is backed up more often than once a day. A
# request for anything sub-daily is rejected, not quietly rounded — a module
# asking for hourly backups is asking for something the platform does not do,
# and silently giving it daily would hide that.
#
# The vocabulary is deliberately three words plus a start time:
#
#   daily | weekly | monthly     the policy language of §3.2
#   HH:MM                        a daily backup at that time — the spelling
#                                existing site/environment configs already use
#                                (e.g. "21:00"), so they keep working unchanged
#
# Anything else (hourly, "*:00", "mon,thu 06:00", a raw sub-daily calendar
# event) is invalid. Keeping the vocabulary small is what makes the ceiling
# enforceable at all: a free-form calendar string cannot be checked against
# "at most once a day" without reimplementing systemd's calendar parser.
#
# ── Buckets ──────────────────────────────────────────────────────────
#
# Proxmox schedules a backup JOB, not a guest, so per-module schedules need one
# job per distinct frequency ("buckets", D16). Each bucket is a cluster backup
# job identified by its own marker comment:
#
#   daily    TAPPaaS-backup-vm-managed           (the pre-existing job — its
#                                                 marker and start time are kept
#                                                 exactly, so an installed site's
#                                                 nightly job is never disturbed)
#   weekly   TAPPaaS-backup-vm-managed-weekly    sun 21:00
#   monthly  TAPPaaS-backup-vm-managed-monthly   *-*-01 21:00
#
# A module belongs to exactly one bucket; changing its schedule moves it, which
# is an add to the new job and a remove from the old, never a duplicate.
#
# Requires: common-install-routines.sh and lib/pbs-job.sh sourced first.

PBS_SCHEDULE_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# Default time of day for every bucket, and the start time the existing daily
# job already carries.
PBS_DEFAULT_STARTTIME="21:00"

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# Classify a schedule spec into its bucket. Echoes daily|weekly|monthly (rc 0)
# or nothing (rc 1) when the spec is not something we will schedule.
pbs_schedule_bucket() {
    local spec="${1:-}"
    case "${spec,,}" in
        ""|daily)  printf 'daily\n' ;;
        weekly)    printf 'weekly\n' ;;
        monthly)   printf 'monthly\n' ;;
        # A bare HH:MM is a daily backup at that time (00:00–23:59).
        [0-2][0-9]:[0-5][0-9])
            [[ "${spec%%:*}" -le 23 ]] || return 1
            printf 'daily\n' ;;
        *) return 1 ;;
    esac
}

# The start time carried by a spec: an explicit HH:MM, else the default.
pbs_schedule_starttime() {
    local spec="${1:-}"
    case "${spec}" in
        [0-2][0-9]:[0-5][0-9]) printf '%s\n' "${spec}" ;;
        *) printf '%s\n' "${PBS_DEFAULT_STARTTIME}" ;;
    esac
}

# The systemd calendar event for <bucket> [starttime].
pbs_schedule_calendar() {
    local bucket="${1:-daily}" at="${2:-${PBS_DEFAULT_STARTTIME}}"
    case "${bucket}" in
        daily)   printf '%s\n' "${at}" ;;
        weekly)  printf 'sun %s\n' "${at}" ;;
        monthly) printf '*-*-01 %s\n' "${at}" ;;
        *) return 1 ;;
    esac
}

# The job marker for <bucket>. The daily bucket keeps the ORIGINAL marker, so
# the job an installed site already has stays the daily job — this migration
# has to be a no-op on every existing deployment.
pbs_bucket_marker() {
    case "${1:-daily}" in
        daily)   printf '%s\n' "${PBS_JOB_MARKER}" ;;
        weekly)  printf '%s-weekly\n' "${PBS_JOB_MARKER}" ;;
        monthly) printf '%s-monthly\n' "${PBS_JOB_MARKER}" ;;
        *) return 1 ;;
    esac
}

# Every bucket name, in frequency order.
pbs_buckets() { printf 'daily\nweekly\nmonthly\n'; }

# Resolve the schedule cascade for <module> (§3.2). Echoes the resolved SPEC.
# Mirrors resolveSchedule() in the TS backup-manager — the two must agree; both
# are unit-tested against the same precedence.
# Args: <module> [config-dir]
pbs_schedule_resolve() {
    local module="$1" dir="${2:-${PBS_SCHEDULE_CONFIG_DIR}}" spec env
    spec="$(jq -r '.backup.schedule // empty' "${dir}/${module}.json" 2>/dev/null || true)"
    if [[ -z "${spec}" ]]; then
        env="$(jq -r '.environment // empty' "${dir}/${module}.json" 2>/dev/null || true)"
        [[ -n "${env}" ]] && spec="$(jq -r '.backup.schedule // empty' \
            "${dir}/environments/${env}.json" 2>/dev/null || true)"
    fi
    [[ -z "${spec}" ]] && spec="$(jq -r '.backup.defaultSchedule // empty' \
        "${dir}/site.json" 2>/dev/null || true)"
    [[ -z "${spec}" ]] && spec="daily"
    printf '%s\n' "${spec}"
}

# The bucket <module> resolves to. Invalid spec ⇒ rc 1 with a named error, so a
# bad schedule fails loudly at the module that declared it rather than silently
# landing in `daily`.
pbs_module_bucket() {
    local module="$1" dir="${2:-${PBS_SCHEDULE_CONFIG_DIR}}" spec bucket
    spec="$(pbs_schedule_resolve "${module}" "${dir}")"
    if ! bucket="$(pbs_schedule_bucket "${spec}")"; then
        error "backup schedule '${spec}' for module '${module}' is not supported — use daily | weekly | monthly | HH:MM (never more often than once a day, ADR-012 §3.2)"
        return 1
    fi
    printf '%s\n' "${bucket}"
}

# ── the file-capture window (#691) ───────────────────────────────────
#
# A file capture runs BEFORE the whole-guest job, so a night's capture and
# snapshot are not taken across the same change, and the two do not contend for
# the backup server. That relationship used to be three separate literals
# ("20:30" in tappaas-common.nix, in tappaas-cicd.nix and in pbs_fs_install_timer)
# with nothing tying them to the VM job's own 21:00 — move the VM window and the
# captures silently ended up after it. Now both come from here.
#
# The lead, in minutes, from the VM job's start back to the capture window.
PBS_FS_LEAD_MINUTES="${PBS_FS_LEAD_MINUTES:-60}"
# How far modules are spread within the window, and the margin left before the
# VM job starts. spread + margin must be <= lead, which pbs_fs_window checks.
PBS_FS_SPREAD_MINUTES="${PBS_FS_SPREAD_MINUTES:-45}"
PBS_FS_MARGIN_MINUTES="${PBS_FS_MARGIN_MINUTES:-15}"

# Minutes since midnight for HH:MM, and back again (wrapping at a day).
_pbs_hm_to_min() { local h="${1%%:*}" m="${1##*:}"; printf '%s' "$((10#${h} * 60 + 10#${m}))"; }
_pbs_min_to_hm() { local t="$(( ($1 % 1440 + 1440) % 1440 ))"; printf '%02d:%02d' "$((t / 60))" "$((t % 60))"; }

# A module's own offset inside the window: DETERMINISTIC, from its name.
#
# Not a wide RandomizedDelaySec: with an hour of jitter a capture lands anywhere
# up to the VM job, so "did it finish before the snapshot?" and "when does this
# module run?" have different answers every night — the two questions an
# operator asks precisely when a backup is missing. A hash gives every module a
# fixed slot, no two collide by luck, and adding a module moves nobody else.
pbs_fs_offset_minutes() {
    local module="$1" spread="${2:-${PBS_FS_SPREAD_MINUTES}}" h
    [[ "${spread}" -gt 0 ]] || { printf '0'; return 0; }
    h="$(printf '%s' "${module}" | cksum | cut -d' ' -f1)"
    printf '%s' "$(( h % spread ))"
}

# The capture time for <module>: HH:MM (rc 0), or rc 1 with a named error when
# the window cannot hold the spread before the VM job starts.
#
# An explicit module schedule of HH:MM is the operator saying "not with the
# others", and wins over the derived window.
pbs_fs_window() {
    local module="$1" dir="${2:-${PBS_SCHEDULE_CONFIG_DIR}}" spec vm_at start off
    spec="$(pbs_schedule_resolve "${module}" "${dir}")"
    if [[ "${spec}" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
        printf '%s\n' "${spec}"; return 0
    fi
    if (( PBS_FS_SPREAD_MINUTES + PBS_FS_MARGIN_MINUTES > PBS_FS_LEAD_MINUTES )); then
        error "backup:filesystem: the capture window (spread ${PBS_FS_SPREAD_MINUTES}m + margin ${PBS_FS_MARGIN_MINUTES}m) does not fit the ${PBS_FS_LEAD_MINUTES}m lead before the ${PBS_DEFAULT_STARTTIME} VM job — captures would run into it"
        return 1
    fi
    vm_at="$(pbs_schedule_starttime "${spec}")"
    start="$(( $(_pbs_hm_to_min "${vm_at}") - PBS_FS_LEAD_MINUTES ))"
    off="$(pbs_fs_offset_minutes "${module}")"
    _pbs_min_to_hm "$(( start + off ))"
    printf '\n'
}

# The systemd OnCalendar for <module>'s capture: the resolved bucket (daily,
# weekly, monthly) at this module's own time inside the window.
pbs_fs_oncalendar() {
    local module="$1" dir="${2:-${PBS_SCHEDULE_CONFIG_DIR}}" bucket at
    bucket="$(pbs_schedule_bucket "$(pbs_schedule_resolve "${module}" "${dir}")")" || {
        error "backup:filesystem: ${module} declares a schedule TAPPaaS will not run"; return 1; }
    at="$(pbs_fs_window "${module}" "${dir}")" || return 1
    pbs_schedule_calendar "${bucket}" "${at}"
}
