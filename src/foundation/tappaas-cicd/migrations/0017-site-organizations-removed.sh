#!/usr/bin/env bash
# 0017-site-organizations-removed.sh — site.json loses organizations[]
#
# Introduced: 2.3.  Required by: #867 (src/DATAMODEL.md finding 4).
# Touches: config/site.json (only).
# Reversible: yes — restore config/.migrations/backup/0017/site.json.
#
# WHY. site.json carried `organizations`, a list of paths to the organization
# files, while identity-manager owns config/identities/organizations/<org>.json.
# Nothing read the list: environment-manager opens an organization's file by
# name, the console lists the directory. The directory is the list, so the
# field is gone from site-fields.json, and `site-manager validate` refuses a
# site.json that still carries it. The organization files are not touched.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a site.json that is not
# a JSON object.
#
# Usage: 0017-site-organizations-removed.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0017}"
SITE="${CONFIG_DIR}/site.json"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo -e "\033[32m[Info]\033[m   0017: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0017: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0017: $*" >&2; exit 1; }

[[ -f "${SITE}" ]] || { say "no ${SITE} — nothing to migrate"; exit 0; }
jq empty "${SITE}" 2>/dev/null || stop "${SITE} is not valid JSON — refusing to touch it"
[[ "$(jq -r 'type' "${SITE}")" == "object" ]] || stop "${SITE} is not a JSON object — a person should look at this"

if [[ "$(jq -r 'has("organizations")' "${SITE}")" != "true" ]]; then
    say "site.json has no organizations field — nothing to migrate"
    exit 0
fi
listed="$(jq -c '.organizations' "${SITE}")"

if [[ "${CHECK}" -eq 1 ]]; then
    say "would remove organizations ${listed} from ${SITE} (the organizations are the files in ${CONFIG_DIR}/identities/organizations/)"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -p "${SITE}" "${BACKUP_DIR}/site.json" || stop "cannot back up ${SITE} — refusing to write"

tmp="${SITE}.0017.tmp"
jq 'del(.organizations)' "${SITE}" > "${tmp}" \
    || { rm -f "${tmp}"; stop "rewrite failed — ${SITE} is unchanged"; }
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten site.json is not valid JSON — ${SITE} is unchanged"; }
chmod --reference="${BACKUP_DIR}/site.json" "${tmp}" 2>/dev/null || true
mv -f "${tmp}" "${SITE}"
say "organizations ${listed} removed from site.json — the organizations are the files in identities/organizations/"
note "backup: ${BACKUP_DIR}/site.json"
