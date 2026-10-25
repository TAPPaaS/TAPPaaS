#!/usr/bin/env bash
# 0024-weekly-default-becomes-daily.sh — a site on the old weekly default updates daily
#
# Introduced: 2.4.  Required by: #801 (operator decision 2026-10-25).
# Touches: config/site.json (only).
# Reversible: yes — restore config/.migrations/backup/0024/site.json.
#
# WHY. Until 2.4 a new site was written to update weekly — create-site.sh on
# Tuesday at 02:00, the schema's default on Thursday — and from 2.4 the default
# is daily on every channel: on stable and staging most runs change nothing,
# and an urgent fix or an OS patch then arrives within a day, not a week (#801).
# A site still on exactly one of those two defaults never chose weekly, so it
# moves to daily at the same hour:
#
#   {"frequency": "weekly", "weekday": "Tuesday",  "hour": 2}  →  {"frequency": "daily", "hour": 2}
#   {"frequency": "weekly", "weekday": "Thursday", "hour": 2}  →  {"frequency": "daily", "hour": 2}
#
# Any other schedule is somebody's choice and is left alone. A site that did
# choose one of the two exact defaults cannot be told apart from one that took
# it, so the change is said, with the command that sets weekly back.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a site.json that is not
# JSON, and an updateSchedule that is still the triple (0003 rewrites it first).
#
# Usage: 0024-weekly-default-becomes-daily.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0024}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained.
say()  { echo -e "\033[32m[Info]\033[m   0024: $*"; }
warn() { echo -e "\033[33m[Warning]\033[m 0024: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0024: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"

case "$(jq -r '.updateSchedule | type' "${SITE}")" in
    null)   say "site.json has no updateSchedule — it already updates daily; nothing to migrate"; exit 0 ;;
    array)  stop "updateSchedule is still the [frequency, weekday, hour] triple — migration 0003 rewrites it first" ;;
    object) : ;;
    *)      stop "updateSchedule is $(jq -c .updateSchedule "${SITE}"), neither an object nor the triple — a person should look at this" ;;
esac

was="$(jq -c '.updateSchedule' "${SITE}")"
if ! jq -e '.updateSchedule | .frequency == "weekly" and (.weekday == "Tuesday" or .weekday == "Thursday")
            and (.hour // 2) == 2 and (keys - ["frequency", "weekday", "hour"] | length) == 0' "${SITE}" >/dev/null; then
    say "updateSchedule ${was} is not the old weekly default — left as it is"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    say "would change updateSchedule ${was} to daily at 02:00 (the old weekly default; #801)"
    exit 0
fi

# Back up before the write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"

tmp="${SITE}.0024.tmp"
jq '.updateSchedule = {"frequency": "daily", "hour": 2}' "${SITE}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — site.json is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten site.json is not valid JSON — it is unchanged"; }
chmod --reference="${BACKUP_DIR}/site.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${SITE}"
day="$(jq -r '.weekday' <<<"${was}")"
warn "the site updated weekly on ${day}s at 02:00 — the old default — and now updates daily at 02:00 (#801). To keep weekly: site-manager site modify --updateFrequency weekly --updateWeekday ${day} --updateHour 2"
