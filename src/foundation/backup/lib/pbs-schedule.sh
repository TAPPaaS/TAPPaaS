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
