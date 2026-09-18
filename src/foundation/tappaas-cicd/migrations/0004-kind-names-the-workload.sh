#!/usr/bin/env bash
# 0004-kind-names-the-workload.sh — `kind` names the workload, not the object type
#
# Introduced: 2.1 (Wave 1, G1.1).  Required by: ADR-022d, ADR-022f D1/D2, #611.
# Touches: config/<module>.json whose top-level `kind` is "module" or "external-host".
# Reversible: yes — restore config/.migrations/backup/0004/<file>.
#
# WHY. `kind` carried two meanings. ADR-007 used it as an object-type marker:
# install-module.sh stamped `"kind": "module"` into every deployed config so the
# managers could tell a module from site.json and the other state files. ADR-022f
# gives the same field the workload type — vm, lxc, machine, application,
# device — which each module now AUTHORS in its source JSON. One field cannot
# say both, and the marker lost: module discovery (#544) already recognises a
# module by its shape, and older installs never carried the marker at all.
#
#   "module"         → removed, when the config has another module signal
#                      (dependsOn / integratesWith / provides / location). The
#                      next update's 3-way merge then ADOPTS the authored kind
#                      (rule 3, a new release field). Without this removal it
#                      never would: a deployed value the release never had reads
#                      as operator-pinned (rule 5) and is kept for ever.
#                      LEFT IN PLACE, and named, when it is the ONLY signal —
#                      removing it would make that module vanish from discovery,
#                      which keeps accepting the marker for exactly this case.
#   "external-host"  → "machine" (ADR-022f D2; the satellite, ADR-010 §8).
#   anything else    → untouched: an authored workload kind is already right.
#
# `cluster` and `templates` carry no kind (the grouping concept is its own ADR);
# they are found by their shape, as before.
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a config/*.json that is
# not valid JSON — it cannot tell whether that file holds a marker.
#
# Usage: 0004-kind-names-the-workload.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a file it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0004}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

say()  { echo "0004: $*"; }
stop() { echo "0004: $*" >&2; exit 1; }

shopt -s nullglob
files=("${CONFIG_DIR}"/*.json)

# Refuse up front, before any write, so a bad file never leaves a half-done run.
for f in ${files[@]+"${files[@]}"}; do
    jq empty "${f}" 2>/dev/null || stop "$(basename "${f}") is not valid JSON — cannot tell whether it carries a kind marker; a person should look at it"
done

drop=(); rename=(); kept=()
for f in ${files[@]+"${files[@]}"}; do
    [[ "$(jq -r 'type' "${f}")" == "object" ]] || continue
    case "$(jq -r '.kind // empty | tostring' "${f}")" in
        module)
            if jq -e '(.dependsOn | type) == "array" or (.integratesWith | type) == "array"
                      or (.provides | type) == "array" or (.location | type) == "string" or (.moduleSource | type) == "string"' "${f}" >/dev/null; then
                drop+=("${f}")
            else
                kept+=("${f}")
            fi ;;
        external-host) rename+=("${f}") ;;
    esac
done

for f in ${kept[@]+"${kept[@]}"}; do
    say "$(basename "${f}"): kind \"module\" KEPT — it is this config's only module signal (no dependsOn/integratesWith/provides/location); removing it would hide the module. Re-install or re-add the module to give it a location."
done

if [[ $(( ${#drop[@]} + ${#rename[@]} )) -eq 0 ]]; then
    say "no kind marker to retire — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    for f in ${drop[@]+"${drop[@]}"};   do say "would remove kind \"module\" from $(basename "${f}")"; done
    for f in ${rename[@]+"${rename[@]}"}; do say "would rewrite kind \"external-host\" → \"machine\" in $(basename "${f}")"; done
    exit 0
fi

# Back up every file before the first write — those copies ARE the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in ${drop[@]+"${drop[@]}"} ${rename[@]+"${rename[@]}"}; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up $(basename "${f}") — nothing has been written"
done

rewrite() {   # rewrite <file> <jq program> <what>
    local f="$1" tmp="$1.0004.tmp"
    # Write INTO a copy of the original, so the result keeps its mode and owner on
    # any platform — ownership is the invariant #525 is about: a root-owned
    # config drops out of the sweep.
    cp -p "${f}" "${tmp}" || stop "cannot stage $(basename "${f}") — it is unchanged"
    jq "$2" "${f}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite of $(basename "${f}") failed — it is unchanged; earlier files are restorable from ${BACKUP_DIR}"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "rewritten $(basename "${f}") is not valid JSON — it is unchanged"; }
    mv -f "${tmp}" "${f}"
    say "$(basename "${f}"): $3"
}
for f in ${drop[@]+"${drop[@]}"};   do rewrite "${f}" 'del(.kind)' 'kind "module" removed — the next update adopts the kind the module authors'; done
for f in ${rename[@]+"${rename[@]}"}; do rewrite "${f}" '.kind = "machine"' 'kind "external-host" → "machine"'; done
say "$(( ${#drop[@]} + ${#rename[@]} )) config(s) migrated (backup: ${BACKUP_DIR})"
