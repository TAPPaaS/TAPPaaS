#!/usr/bin/env bash
# 0006-location-becomes-module-source.sh — a module's `location` becomes `moduleSource`
#
# Introduced: 2.1 (Wave 1, G1.2).  Required by: #609 (operator, 2026-09-18).
# Touches: config/<instance>.json whose top-level `location` is a string.
# Reversible: yes — restore config/.migrations/backup/0006/<file>.
#
# WHY. `location` on a deployed config was the absolute path of the module's
# source directory — what `module_of`, get_module_dir and the 3-way merge read.
# #609 needs the word for a PLACE: an off-site copy records where it physically
# is (`physicalLocation`, ADR-012 §1.5), and site.json's `location` already is a
# place. One word for a directory and a country, on the same machine config,
# is the confusion this removes.
#
#   "location": "<path>"                  → "moduleSource": "<path>", in the
#                                           same position; `location` removed
#   both, the same path                   → `location` removed
#   anything else                         → untouched: a `location` that is not
#                                           a string is a place (site.json), not
#                                           a source directory
#
# Every reader accepts both names for one stable cycle (a restored backup, or a
# site on an older release, may still hold `location`), so the order in which
# this and the code arrive does not matter.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is
# not valid JSON, and one carrying BOTH names with different paths — which one
# the module lives at is a person's call.
#
# Usage: 0006-location-becomes-module-source.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a file it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0006}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo "0006: $*"; }
stop() { echo "0006: $*" >&2; exit 1; }

shopt -s nullglob
files=("${CONFIG_DIR}"/*.json)

# Refuse up front, before any write, so a bad file never leaves a half-done run.
for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — cannot tell whether it records a module source; a person should look at it"
    if jq -e 'type == "object" and (.location | type) == "string" and (.moduleSource | type) == "string"
              and .location != .moduleSource' "${f}" >/dev/null; then
        stop "$(basename "${f}") has both location '$(jq -r .location "${f}")' and moduleSource '$(jq -r .moduleSource "${f}")' — which one the module lives at is a person's call; remove the wrong one, then re-run"
    fi
done

todo=()
for f in ${files[@]+"${files[@]}"}; do
    jq -e 'type == "object" and (.location | type) == "string"' "${f}" >/dev/null && todo+=("${f}")
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "no module records its source as location — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would rename location → moduleSource in $(basename "${f}")"; done
    exit 0
fi

# Back up every file before the first write — those copies ARE the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

for f in "${todo[@]}"; do
    tmp="${f}.0006.tmp"
    # Write INTO a copy of the original, so the result keeps its mode and owner
    # (#525: a root-owned config drops out of the sweep).
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    # with_entries keeps the key where it was; a moduleSource already present
    # (equal, checked above) makes the renamed key a duplicate, and the later
    # entry wins in jq — the same value either way.
    jq 'if has("moduleSource") then del(.location)
        else with_entries(if .key == "location" then .key = "moduleSource" else . end) end' "${f}" > "${tmp}" \
        || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq -e '(.moduleSource | type) == "string" and (has("location") | not)' "${tmp}" >/dev/null 2>&1 \
        || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") is not what was intended — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    say "$(basename "${f}"): location → moduleSource"
done
say "${#todo[@]} config(s) migrated (backup: ${BACKUP_DIR})"
