#!/usr/bin/env bash
# 0008-satellite-records-its-module.sh — a satellite config records its moduleSource
#
# Introduced: 2.1 (Wave 1, G1.2).  Required by: #609 follow-up, ADR-026 (a satellite is a machine module).
# Touches: config/satellite-<name>.json that records no moduleSource (nor its old name, location).
# Reversible: yes — restore config/.migrations/backup/0008/<file>.
#
# WHY. A satellite config was written by satellite-manager (retired by ADR-010
# §8.4), not by the module installer, so it never recorded where the satellite
# module's code lives. Since
# #611 it carries `kind: machine`, so discovery lists it as a module — and then
# nothing can name its module: `module list --resolution` reports it
# `unresolvable` (seen on makerfloss, 2026-09-19). A new satellite is added by
# `module-manager module add`, which records `moduleSource`; this gives existing
# ones the same.
#
#   satellite-*.json, no moduleSource/location → "moduleSource": "<repo>/src/foundation/satellite"
#   anything else                             → untouched
#
# The path is the satellite module's directory beside the tappaas-cicd module this
# site already records (config/tappaas-cicd.json moduleSource, or location) —
# deliberately not where this script happens to run from, so a preview from a
# scratch checkout can never record a scratch path.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is
# not valid JSON; and a satellite to backfill when the satellite module's
# directory cannot be derived, or does not exist there.
#
# Usage: 0008-satellite-records-its-module.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a state it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0008}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo "0008: $*"; }
stop() { echo "0008: $*" >&2; exit 1; }

shopt -s nullglob
files=("${CONFIG_DIR}"/satellite-*.json)

for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — a person should look at it"
done

todo=()
for f in ${files[@]+"${files[@]}"}; do
    jq -e 'type == "object"
           and ((.moduleSource // "") | type == "string" and . == "")
           and ((.location // "") | type != "string" or . == "")' "${f}" >/dev/null && todo+=("${f}")
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "every satellite config records its module — nothing to migrate"
    exit 0
fi

cicd="$(jq -r 'if type == "object" then (.moduleSource // (if (.location | type) == "string" then .location else "" end) // "") else "" end' \
    "${CONFIG_DIR}/tappaas-cicd.json" 2>/dev/null || true)"
[[ -n "${cicd}" ]] \
    || stop "config/tappaas-cicd.json records no moduleSource — cannot tell where the satellite module lives; a person should look at it"
src="$(dirname "${cicd}")/satellite"
[[ -d "${src}" ]] \
    || stop "the satellite module is not at ${src} (beside ${cicd}) — nothing was changed"

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would record moduleSource ${src} in $(basename "${f}")"; done
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

for f in "${todo[@]}"; do
    tmp="${f}.0008.tmp"
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    jq --arg s "${src}" '(if .location == "" then del(.location) else . end) | .moduleSource = $s' "${f}" > "${tmp}" \
        || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq -e --arg s "${src}" '.moduleSource == $s' "${tmp}" >/dev/null 2>&1 \
        || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") is not what was intended — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    say "$(basename "${f}"): moduleSource = ${src}"
done
say "${#todo[@]} satellite config(s) migrated (backup: ${BACKUP_DIR})"
