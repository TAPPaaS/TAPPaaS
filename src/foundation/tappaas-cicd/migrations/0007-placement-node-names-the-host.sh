#!/usr/bin/env bash
# 0007-placement-node-names-the-host.sh — `node:<host>` becomes `node` + `.node`
#
# Introduced: 2.1 (Wave 1, G1.2).  Required by: #600, ADR-012 v1.0 §2.1.
# Touches: config/*.json whose `placementState` is "node:<host>" (the backup module).
# Reversible: yes — restore config/.migrations/backup/0007/<file>.
#
# WHY. The backup module stored the Host its PBS runs on inside the state
# (`placementState: "node:tappaas3"`), and kept `.node` as the operator's
# discovery constraint. ADR-012 §2.1 decides the other shape: `placementState:
# "node"`, with `.node` naming the Host — a cluster node or, since ADR-026, a
# `kind: machine` instance. One field for the Host, and a state value that no
# longer carries data.
#
#   "placementState": "node:<host>"  → "placementState": "node", "node": "<host>"
#   anything else                    → untouched
#
# `.node` is overwritten with the Host: after resolution it names the Host, not
# a constraint. A different value there was a constraint the resolution already
# acted on; it is REPORTED, and kept in the backup. The module reads both shapes
# for one stable cycle, so the order in which this and the code arrive does not
# matter.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is
# not valid JSON, and a state `node:` naming no Host.
#
# Usage: 0007-placement-node-names-the-host.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a file it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0007}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo "0007: $*"; }
stop() { echo "0007: $*" >&2; exit 1; }

shopt -s nullglob
files=("${CONFIG_DIR}"/*.json)

for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — cannot tell whether it records a placement; a person should look at it"
    if jq -e 'type == "object" and .placementState == "node:"' "${f}" >/dev/null; then
        stop "$(basename "${f}") has placementState \"node:\" naming no Host — a person should look at it"
    fi
done

todo=()
for f in ${files[@]+"${files[@]}"}; do
    jq -e 'type == "object" and ((.placementState // "") | type == "string" and startswith("node:"))' "${f}" >/dev/null && todo+=("${f}")
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "no placement records its Host in the state — nothing to migrate"
    exit 0
fi

describe() {  # describe <file> → what the rewrite does, and a replaced constraint
    local host old
    host="$(jq -r '.placementState | ltrimstr("node:")' "$1")"
    old="$(jq -r '.node // ""' "$1")"
    printf '%s: placementState node:%s → node, node = %s' "$(basename "$1")" "${host}" "${host}"
    [[ -n "${old}" && "${old}" != "${host}" ]] && printf ' (replaces the constraint "%s" — resolution already acted on it)' "${old}"
    printf '\n'
}

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would rewrite $(describe "${f}")"; done
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

for f in "${todo[@]}"; do
    msg="$(describe "${f}")"
    tmp="${f}.0007.tmp"
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    jq '(.placementState | ltrimstr("node:")) as $h | .placementState = "node" | .node = $h' "${f}" > "${tmp}" \
        || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq -e '.placementState == "node" and (.node | type == "string" and length > 0)' "${tmp}" >/dev/null 2>&1 \
        || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") is not what was intended — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    say "${msg}"
done
say "${#todo[@]} config(s) migrated (backup: ${BACKUP_DIR})"
