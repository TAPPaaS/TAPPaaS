#!/usr/bin/env bash
#
# compose-fields.sh — emit the merged module-field schema on stdout (#567).
#
# Field definitions now live with the service that owns them, in three tiers:
#
#   schemas/module-fields.json           fields no service owns (provenance,
#                                        lifecycle, wiring) — the generic ones
#   <module>/fields.json                 shared by that module's services
#   <module>/services/<svc>/fields.json  owned by exactly one service
#
# This composes them back into the single document readers expect, so the SOURCE
# of a definition moved without every consumer moving with it.
#
# In jq, not TypeScript, deliberately: bash and Python readers must not need
# node, and this also runs before any manager is built. lib/ts/src/compose-
# fields.ts is the in-process twin for TypeScript callers; a unit test asserts
# the two agree, because two implementations that disagree are worse than one.
#
# Usage: compose-fields.sh [<foundation-dir>]
#
# Note on WHERE this may run: nothing on a Proxmox node needs it. Node-side
# scripts (Create-TAPPaaS-VM.sh and friends, shipped to /root/tappaas/) are
# self-contained — they read the module JSON scp'd alongside them and carry
# their own defaults, and the node has neither the repo nor the shared libs.
# The schema is a mothership concern.
set -euo pipefail

FOUNDATION="${1:-/home/tappaas/TAPPaaS/src/foundation}"
# Normalised: the same file reached by two different path spellings (a caller
# passing "<dir>/.." and the repo root from site.json) must dedup to ONE entry,
# or it is reported as a field defined in two tiers.
FOUNDATION="$(cd "${FOUNDATION}" 2>/dev/null && pwd -P || printf '%s' "${FOUNDATION}")"
BASE="${FOUNDATION}/schemas/module-fields.json"

[[ -f "${BASE}" ]] || { echo "compose-fields.sh: no ${BASE}" >&2; exit 1; }

# The keys that are CHANGE semantics, not part of a field's definition. An entry
# holding only these defines nothing — it is a manifest entry for a field
# defined in another tier, which is the pre-#567 shape and must not shadow it.
readonly CHANGE_KEYS='["class","apply","liveKey","setFlag","hook","composite","normalize","sideEffects","changeNote","inputs"]'

# ── discovery ────────────────────────────────────────────────────────
#
# Walk the REGISTERED MODULES, not the filesystem. site.json .repositories is
# the canonical repo list (ADR-007), and each repo's module-catalog.json is the
# canonical list of what is a module in it. That is a stronger answer than
# scanning for directory shapes: a stray services/ directory in someone's repo
# is not a module, an unregistered checkout is not a source of fields, and
# neither can leak into the schema every reader trusts.
#
# It also removes the guesswork the filesystem walk needed — no prune list, no
# depth limit, no rule for telling a module directory from any other directory.
# Layout stops mattering: foundation modules sit at src/foundation/<module>/ and
# community ones at src/<author>/<group>/<module>/, and both are simply
# dirname(moduleJson).
#
# Per registered module, two tiers:
#   <module>/fields.json                shared by that module's own services
#   <module>/services/<svc>/fields.json owned by one service
_roots=()
_site="${CONFIG_DIR:-/home/tappaas/config}/site.json"

tier_files=()
_seen=""
_add_tier() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    f="$(cd "$(dirname "${f}")" && pwd -P)/$(basename "${f}")"
    case " ${_seen} " in *" ${f} "*) return 0 ;; esac
    _seen+=" ${f}"
    tier_files+=("${f}")
}

_scan_repo() { # _scan_repo <repo-root> <catalog-relative-path>
    local root="$1" cat_rel="${2:-src/module-catalog.json}"
    local cat="${root}/${cat_rel}"
    [[ -r "${cat}" ]] || return 0
    local mj dir
    while IFS= read -r mj; do
        [[ -n "${mj}" ]] || continue
        dir="${root}/$(dirname "${mj}")"
        [[ -d "${dir}" ]] || continue
        _add_tier "${dir}/fields.json"
        local sf
        for sf in "${dir}"/services/*/fields.json; do _add_tier "${sf}"; done
    done < <(jq -r '[.. | objects | select(has("moduleJson")) | .moduleJson] | .[]' "${cat}" 2>/dev/null || true)
}

if [[ -r "${_site}" ]] && command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r rpath rcat; do
        [[ -n "${rpath}" && -d "${rpath}" ]] || continue
        _scan_repo "$(cd "${rpath}" && pwd -P)" "${rcat}"
    done < <(jq -r '.repositories[]? | [(.path // empty), (.catalog // "src/module-catalog.json")] | @tsv' "${_site}" 2>/dev/null || true)
fi

# Bootstrap / bare checkout: no site.json yet, or it lists no usable repo. Fall
# back to the catalogue of the tree this composer ships in, so the generic
# fields still resolve and an install can proceed.
if [[ "${#tier_files[@]}" -eq 0 ]]; then
    _scan_repo "$(cd "${FOUNDATION}/../.." && pwd -P)" "src/module-catalog.json"
fi

# Compose in the shell: start from the base document and fold each tier file
# into its .fields. A definition appearing twice is an ERROR — two files
# claiming one field is the ambiguity this change removes.
merged="$(cat "${BASE}")"
dupes=""
for f in "${tier_files[@]}"; do
    [[ -f "$f" ]] || continue
    rel="${f#/home/tappaas/}"
    add="$(jq -c --argjson ck "${CHANGE_KEYS}" '
        (.fields // {})
        | with_entries(
            .value |= with_entries(select(.key as $k | $ck | index($k) | not))
          )
        | with_entries(select((.value | length) > 0))' "$f")"
    dup="$(jq -r -n --argjson m "${merged}" --argjson a "${add}" '
        [$a | keys[] as $k | select(($m.fields // {}) | has($k)) | $k] | join(" ")')"
    [[ -n "${dup}" ]] && dupes+=" ${rel}:${dup}"
    merged="$(jq -c --argjson a "${add}" '.fields = ((.fields // {}) + $a)' <<< "${merged}")"
done

if [[ -n "${dupes}" ]]; then
    echo "compose-fields.sh: field(s) defined in more than one tier —${dupes}" >&2
    echo "  One definition, one home. Remove the duplicate." >&2
    exit 1
fi

jq . <<< "${merged}"
