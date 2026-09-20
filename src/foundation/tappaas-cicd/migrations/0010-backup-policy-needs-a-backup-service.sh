#!/usr/bin/env bash
# 0010-backup-policy-needs-a-backup-service.sh — drop a backup policy that backs nothing up
#
# Introduced: 2.1 (Wave 1, G1.2).  Required by: #672 follow-up (found in the 2026-09-19 sweep).
# Touches: config/*.json with a top-level `backup` and no backup service wired.
# Reversible: yes — restore config/.migrations/backup/0010/<file>.
#
# WHY. install-module.sh recorded the resolved backup policy (ADR-007 P9) into
# EVERY module's config, including ones that wire no backup service at all. On
# such a module the policy backs nothing up, and the config merge warns
# "field 'backup' is usedBy=[backup:vm,backup:filesystem] but the module does
# not depend on any of them — kept at top level" on every update — three times a
# sweep on a three-node site, where the cluster nodes are machine instances.
# install-module.sh now records it only where a backup service is wired; this
# removes what it already wrote.
#
#   backup present, no backup service wired → `backup` removed
#   anything else                           → untouched
#
# "Wired" is the converter's own test (convert-json-to-config.sh): dependsOn or
# integratesWith names backup:vm / backup:filesystem, OR the module provides the
# service itself (the backup module provides vm + filesystem, and reads its own
# policy from the top level). So backup.json keeps its policy, a module that
# integratesWith backup:filesystem keeps its filesystemPaths, and only a config
# the merge would warn about loses the field.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is
# not valid JSON. A config that is not a module (site.json carries a `backup`
# of its own — the site-wide target and schedule) is left alone: only a config
# naming a module is considered — a `kind`, a `moduleSource`, or a `location`
# that is a PATH. site.json's `location` is a physical place (an object), which
# is exactly the trap ADR-026 D6.2 names, so the test is type-checked.
#
# Usage: 0010-backup-policy-needs-a-backup-service.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a state it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0010}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0010: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0010: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0010: $*" >&2; exit 1; }

# A module config with a `backup` that no backup service reads.
ORPHAN_FILTER='
  type == "object"
  and has("backup")
  and (((.kind // "") | type == "string" and . != "")
       or ((.moduleSource // "") | type == "string" and . != "")
       or ((.location // "") | type == "string" and . != ""))
  and (((.dependsOn // []) + (.integratesWith // [])) as $d
       | (.provides // []) as $p
       | (($d | index("backup:vm") or index("backup:filesystem"))
          or ($p | index("vm") or index("filesystem"))) | not)'

shopt -s nullglob
files=("${CONFIG_DIR}"/*.json)

for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — a person should look at it"
done

todo=()
for f in ${files[@]+"${files[@]}"}; do
    jq -e "${ORPHAN_FILTER}" "${f}" >/dev/null 2>&1 && todo+=("${f}")
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "every recorded backup policy has a backup service — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would remove the backup policy from $(basename "${f}") (it wires no backup service)"; done
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

for f in "${todo[@]}"; do
    tmp="${f}.0010.tmp"
    # Write INTO a copy of the original, so the result keeps its mode and owner.
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    jq 'del(.backup)' "${f}" > "${tmp}" \
        || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq -e 'has("backup") | not' "${tmp}" >/dev/null 2>&1 \
        || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") still has a backup policy — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    note "$(basename "${f}"): backup policy removed (no backup service wired)"
done
say "${#todo[@]} config(s) no longer record a backup policy they cannot use"
note "backup: ${BACKUP_DIR}"
