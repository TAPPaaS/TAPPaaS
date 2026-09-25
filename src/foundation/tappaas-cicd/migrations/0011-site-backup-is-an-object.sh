#!/usr/bin/env bash
# 0011-site-backup-is-an-object.sh — site.json backup: true|false becomes {} | null
#
# Introduced: 2.1.  Required by: #737 (schemas/site-fields.json: backup is an object or null).
# Touches: config/site.json (only).
# Reversible: yes — restore config/.migrations/backup/0011/site.json.
#
# WHY. Older sites carry `"backup": true`. The schema wants the site-wide backup
# settings object (target, defaultSchedule, defaultRetention, …; every key has a
# default) or null for "no backup configured yet", so `site-manager validate`
# fails on the boolean, and nothing current writes one:
#
#   true   →  {}     backup is configured; every setting takes its default
#   false  →  null   no backup configured
#
# `true` never named a target, so {} carries none either; the migration says so,
# rather than inventing one — `backup-manager` reports a job with no target.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): any other non-object value.
#
# Usage: 0011-site-backup-is-an-object.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0011}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0011: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0011: $*"; }
warn() { echo -e "\033[33m[Warning]\033[m 0011: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0011: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"

kind="$(jq -r 'if has("backup") then (.backup | type) else "absent" end' "${SITE}")"
case "${kind}" in
    absent|null|object)
        say "site.json backup is already ${kind} — nothing to migrate"; exit 0 ;;
    boolean) : ;;
    *) stop "site.json backup is a ${kind} ($(jq -c .backup "${SITE}")), neither a boolean nor the settings object — a person should look at this" ;;
esac

if [[ "$(jq -r '.backup' "${SITE}")" == "true" ]]; then
    new='{}'
    why="backup stays configured, with every setting at its default"
else
    new='null'
    why="no backup configured"
fi

if [[ "${CHECK}" -eq 1 ]]; then
    say "would rewrite backup $(jq -c .backup "${SITE}") → ${new} in ${SITE} (${why})"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"

tmp="${SITE}.0011.tmp"
jq --argjson b "${new}" '.backup = $b' "${SITE}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — ${SITE} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten site.json is not valid JSON — ${SITE} is unchanged"; }
chmod --reference="${BACKUP_DIR}/site.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${SITE}"
say "backup → ${new} (${why})"
[[ "${new}" == "{}" ]] && warn "no backup target is recorded (true never named one); set it with backup-manager if this site has a PBS"
note "backup: ${BACKUP_DIR}/site.json"
