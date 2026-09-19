#!/usr/bin/env bash
# 0009-pvenode-becomes-pvehost.sh — the cluster-node module pvenode is renamed pvehost
#
# Introduced: 2.1 (Wave 1, G1.2).  Required by: #665 (operator decision, 2026-09-19).
# Touches: config/*.json whose moduleSource is <repo>/src/foundation/pvenode.
# Reversible: yes — restore config/.migrations/backup/0009/<file>.
#
# WHY. Cluster nodes became instances of a machine module the day it was built
# (#665 stage 1, ADR-026 D4), under the name pvenode; the module is pvehost, the
# Proxmox VE sibling of debianhost. An instance names its module by moduleSource
# (ADR-026 D6.2), so every registered node would otherwise point at a directory
# that no longer exists.
#
#   moduleSource ".../pvenode" → ".../pvehost"   (same repo, same parent)
#   anything else              → untouched
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is not
# valid JSON; and a rewrite whose target directory does not exist — the code this
# migration was pulled with ships it, so its absence means a checkout this
# migration does not understand.
#
# Usage: 0009-pvenode-becomes-pvehost.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a state it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0009}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0009: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0009: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0009: $*" >&2; exit 1; }

shopt -s nullglob
files=("${CONFIG_DIR}"/*.json)

for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — a person should look at it"
done

todo=()
for f in ${files[@]+"${files[@]}"}; do
    jq -e 'type == "object" and ((.moduleSource // "") | type == "string" and endswith("/pvenode"))' \
        "${f}" >/dev/null && todo+=("${f}")
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "no config names the pvenode module — nothing to migrate"
    exit 0
fi

for f in "${todo[@]}"; do
    old="$(jq -r .moduleSource "${f}")"
    new="${old%/pvenode}/pvehost"
    [[ -d "${new}" ]] || stop "$(basename "${f}"): the pvehost module is not at ${new} — nothing was changed"
done

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would point $(basename "${f}") at the pvehost module"; done
    exit 0
fi

mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

for f in "${todo[@]}"; do
    new="$(jq -r .moduleSource "${f}")"; new="${new%/pvenode}/pvehost"
    tmp="${f}.0009.tmp"
    # Write INTO a copy of the original, so the result keeps its mode and owner.
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    jq --arg s "${new}" '.moduleSource = $s' "${f}" > "${tmp}" \
        || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq -e --arg s "${new}" '.moduleSource == $s' "${tmp}" >/dev/null 2>&1 \
        || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") is not what was intended — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    note "$(basename "${f}"): moduleSource = ${new}"
done
say "${#todo[@]} config(s) now name the pvehost module"
note "backup: ${BACKUP_DIR}"
