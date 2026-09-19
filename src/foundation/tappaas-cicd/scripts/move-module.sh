#!/usr/bin/env bash
#
# move-module.sh — move a module within a repository or between repositories,
# and write the config migration that makes every installed site follow (#500).
#
#   move-module.sh <Repo>:<path> <Repo>:<path> [--rename] [--new]
#                  [--checkout <Repo>=<dir>]... [--this-repo <Repo>]
#
#   move-module.sh TAPPaaS:src/apps/hass TAPPaaS:src/stacks/home/hass
#   move-module.sh Community:src/apps/foo TAPPaaS:src/apps/foo --checkout Community=~/src/Community
#
# A repository is named as in a site's site.json `repositories[].name` (TAPPaaS,
# Community, …); each site resolves the name to its own checkout when the
# migration runs. Run it in a TAPPaaS checkout — the repository whose
# migrations/ every site runs (#500: one ledger) — which is also the checkout it
# knows as <this-repo> (default TAPPaaS). Another repository's checkout is given
# with --checkout.
#
# What it does:
#   1. moves the files — `git mv` within one checkout; copy + `git add` / `git rm`
#      between two known checkouts; otherwise it says what to move by hand
#   2. updates the catalogue (src/module-catalog.json) in each known checkout:
#      the entry's moduleJson (and moduleName on --rename), or out of the old
#      repository's catalogue and into the new one's
#   3. adds the move to a migration, migrations/NNNN-modules-moved.sh, with its
#      fixture test. While that migration is uncommitted, every further run adds
#      to it; once committed a new one is started (a number never changes meaning,
#      ADR-025 D1). --new starts a new one regardless.
#
# A module's name is the last part of its path. Changing it is a rename: it
# needs --rename, and is refused while another module in a known checkout names
# the old one in dependsOn/integratesWith (the migration checks deployed configs
# the same way).
#
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/../../../.." && pwd)"
MIG_DIR="${ROOT}/src/foundation/tappaas-cicd/migrations"
TEST_DIR="${ROOT}/src/foundation/tappaas-cicd/scripts/test"
CATALOG_REL="src/module-catalog.json"
RELEASE="${TAPPAAS_RELEASE:-2.1}"

die()  { echo "${SCRIPT_NAME}: $*" >&2; exit 1; }
info() { echo "$*"; }
warn() { echo "${SCRIPT_NAME}: warning: $*" >&2; }

usage() { sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

FROM="" TO="" RENAME=0 NEW=0 THIS_REPO="TAPPaaS"
CHECKOUTS=""   # "<Repo>=<dir>" lines (bash 3 on macOS has no associative arrays)
checkout() { printf '%s\n' "${CHECKOUTS}" | awk -F= -v r="$1" '$1 == r {print substr($0, length(r) + 2); exit}'; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --rename) RENAME=1 ;;
        --new) NEW=1 ;;
        --this-repo) THIS_REPO="${2:?--this-repo needs a name}"; shift ;;
        --checkout)
            [[ "${2:-}" == ?*=?* ]] || die "--checkout takes <Repo>=<dir>"
            _d="$(cd "${2#*=}" 2>/dev/null && pwd)" || die "--checkout ${2}: no such directory"
            CHECKOUTS+="${2%%=*}=${_d}"$'\n'
            shift ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) if [[ -z "${FROM}" ]]; then FROM="$1"; elif [[ -z "${TO}" ]]; then TO="$1"; else die "unexpected argument $1"; fi ;;
    esac
    shift
done
[[ -n "${FROM}" && -n "${TO}" ]] || { usage >&2; exit 2; }
CHECKOUTS+="${THIS_REPO}=${ROOT}"$'\n'

# ── the move ─────────────────────────────────────────────────────────
valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+:[^/:][^:]*$ && "$1" != *..* ]]; }
valid "${FROM}" || die "'${FROM}' is not <Repo>:<path> (a path inside the repository, no leading /, no ..)"
valid "${TO}"   || die "'${TO}' is not <Repo>:<path> (a path inside the repository, no leading /, no ..)"
FROM="${FROM%/}"; TO="${TO%/}"
[[ "${FROM}" != "${TO}" ]] || die "from and to are the same"
FREPO="${FROM%%:*}"; FREL="${FROM#*:}"; TREPO="${TO%%:*}"; TREL="${TO#*:}"
ONAME="${FREL##*/}"; NNAME="${TREL##*/}"
if [[ "${ONAME}" != "${NNAME}" && "${RENAME}" -eq 0 ]]; then
    die "this renames the module ${ONAME} to ${NNAME} — say --rename if that is meant"
fi
FDIR="$(checkout "${FREPO}")"; TDIR="$(checkout "${TREPO}")"
[[ -n "${FDIR}${TDIR}" ]] || die "neither ${FREPO} nor ${TREPO} is a checkout known here (this one is ${THIS_REPO}; add --checkout <Repo>=<dir>)"

if [[ -n "${FDIR}" ]]; then
    [[ -d "${FDIR}/${FREL}" ]] || die "${FROM}: no such directory ${FDIR}/${FREL}"
    [[ -f "${FDIR}/${FREL}/${ONAME}.json" ]] || die "${FROM} holds no ${ONAME}.json — not a module directory"
fi
if [[ -n "${TDIR}" && -e "${TDIR}/${TREL}" ]]; then
    die "${TO} already exists (${TDIR}/${TREL})"
fi

# A rename must not strand a dependency coordinate in a known checkout.
if [[ "${ONAME}" != "${NNAME}" ]]; then
    refs=""
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        while IFS= read -r j; do
            jq -e --arg m "${ONAME}" '((.dependsOn // []) + (.integratesWith // []))
                | map(select(type == "string" and startswith($m + ":"))) | length > 0' "${j}" >/dev/null 2>&1 \
                && refs+="  ${j}"$'\n'
        done < <(find "${d}/src" -name '*.json' -not -path '*/node_modules/*' 2>/dev/null)
    done < <(printf '%s\n' "${CHECKOUTS}" | sed -n 's/^[^=]*=//p')
    [[ -z "${refs}" ]] || die "${ONAME} is still named in dependsOn/integratesWith by:"$'\n'"${refs}change those to ${NNAME} first"
fi

# ── 1. the files ─────────────────────────────────────────────────────
if [[ -n "${FDIR}" && "${FDIR}" == "${TDIR}" ]]; then
    mkdir -p "$(dirname "${TDIR}/${TREL}")"
    git -C "${TDIR}" mv "${FREL}" "${TREL}"
    [[ "${ONAME}" == "${NNAME}" ]] || git -C "${TDIR}" mv "${TREL}/${ONAME}.json" "${TREL}/${NNAME}.json"
    info "moved ${FROM} → ${TO} (git mv)"
elif [[ -n "${FDIR}" && -n "${TDIR}" ]]; then
    mkdir -p "$(dirname "${TDIR}/${TREL}")"
    cp -a "${FDIR}/${FREL}" "${TDIR}/${TREL}"
    [[ "${ONAME}" == "${NNAME}" ]] || mv "${TDIR}/${TREL}/${ONAME}.json" "${TDIR}/${TREL}/${NNAME}.json"
    git -C "${TDIR}" add "${TREL}"
    git -C "${FDIR}" rm -r -q "${FREL}"
    info "moved ${FROM} → ${TO} (copied into ${TREPO}, removed from ${FREPO} — commit both)"
else
    warn "only one end is checked out here: move ${FROM} → ${TO} by hand (and its catalogue entry), then commit both repositories"
fi
[[ "${ONAME}" == "${NNAME}" ]] || warn "other files naming ${ONAME} inside the module are yours to rename"

# ── 2. the catalogues ────────────────────────────────────────────────
entry=""
if [[ -n "${FDIR}" && -f "${FDIR}/${CATALOG_REL}" ]]; then
    entry="$(jq -c --arg j "${FREL}/${ONAME}.json" '[to_entries[] | select(.value | type == "array") | .key as $k
               | .value[] | select(.moduleJson == $j) | {list: $k, e: .}][0] // empty' "${FDIR}/${CATALOG_REL}")"
    [[ -n "${entry}" ]] || warn "${FREPO}'s catalogue has no entry for ${FREL}/${ONAME}.json"
fi
new_json="${TREL}/${NNAME}.json"
if [[ -n "${entry}" ]]; then
    list="$(jq -r .list <<< "${entry}")"
    moved="$(jq -c --arg j "${new_json}" --arg n "${NNAME}" --argjson r "${RENAME}" \
        '.e | .moduleJson = $j | (if $r == 1 then .moduleName = $n else . end)' <<< "${entry}")"
    if [[ "${FDIR}" == "${TDIR}" ]]; then
        # Edited as text, so the catalogue keeps its own layout (it is not all
        # jq-formatted): the path is unique, and so is a module's name.
        cat_f="${FDIR}/${CATALOG_REL}"
        [[ "$(grep -c "\"moduleJson\": *\"${FREL}/${ONAME}.json\"" "${cat_f}")" -eq 1 ]] \
            || die "catalogue: ${FREL}/${ONAME}.json is not named exactly once — edit it by hand"
        sed -i.bak "s#\(\"moduleJson\": *\"\)${FREL}/${ONAME}.json\"#\1${new_json}\"#" "${cat_f}"
        if [[ "${ONAME}" != "${NNAME}" ]]; then
            [[ "$(grep -c "\"moduleName\": *\"${ONAME}\"" "${cat_f}")" -eq 1 ]] \
                || { mv "${cat_f}.bak" "${cat_f}"; die "catalogue: the name ${ONAME} is not unique — edit it by hand"; }
            sed -i.bak2 "s#\(\"moduleName\": *\"\)${ONAME}\"#\1${NNAME}\"#" "${cat_f}" && rm -f "${cat_f}.bak2"
        fi
        rm -f "${cat_f}.bak"
        jq -e --arg j "${new_json}" '[.. | objects | select(.moduleJson? == $j)] | length == 1' "${cat_f}" >/dev/null \
            || die "catalogue: the edit did not leave one entry for ${new_json} — check ${cat_f}"
        info "catalogue: ${list} entry now ${new_json}"
    else
        tmp="$(mktemp)"
        jq --arg l "${list}" --arg j "${FREL}/${ONAME}.json" '.[$l] |= map(select(.moduleJson != $j))' \
            "${FDIR}/${CATALOG_REL}" > "${tmp}" && mv "${tmp}" "${FDIR}/${CATALOG_REL}"
        info "catalogue: removed from ${FREPO}"
        if [[ -n "${TDIR}" && -f "${TDIR}/${CATALOG_REL}" ]]; then
            tmp="$(mktemp)"
            jq --arg l "${list}" --argjson m "${moved}" '.[$l] = ((.[$l] // []) + [$m])' \
                "${TDIR}/${CATALOG_REL}" > "${tmp}" && mv "${tmp}" "${TDIR}/${CATALOG_REL}"
            info "catalogue: added to ${TREPO} (${list})"
        else
            warn "add the entry to ${TREPO}'s catalogue by hand: ${moved}"
        fi
    fi
fi

# ── 3. the migration ─────────────────────────────────────────────────
committed() { git -C "${ROOT}" cat-file -e "HEAD:${1#${ROOT}/}" 2>/dev/null; }
mig=""
if [[ "${NEW}" -eq 0 ]]; then
    for f in $(ls -1 "${MIG_DIR}"/[0-9][0-9][0-9][0-9]-modules-moved.sh 2>/dev/null | sort -r); do
        committed "${f}" || { mig="${f}"; break; }
        break   # the newest is committed: it is sealed
    done
fi
if [[ -z "${mig}" ]]; then
    last="$(ls -1 "${MIG_DIR}" | sed -n 's/^\([0-9]\{4\}\)-.*\.sh$/\1/p' | sort | tail -1)"
    id="$(printf '%04d' $((10#${last:-0} + 1)))"
    mig="${MIG_DIR}/${id}-modules-moved.sh"
    sed -e "s/@@ID@@/${id}/g" -e "s/@@RELEASE@@/${RELEASE}/g" "${HERE}/move-module/migration.tmpl" > "${mig}"
    chmod +x "${mig}"
    sed -e "s/@@ID@@/${id}/g" "${HERE}/move-module/test.tmpl" > "${TEST_DIR}/test-migration-${id}-modules-moved.sh"
    chmod +x "${TEST_DIR}/test-migration-${id}-modules-moved.sh"
    readme="${MIG_DIR}/README.md"
    if [[ -f "${readme}" ]] && ! grep -q "${id}-modules-moved.sh" "${readme}"; then
        row="| \`${id}-modules-moved.sh\` | Installed modules follow the moves in its table (written by \`scripts/move-module.sh\`, #500): a config whose \`moduleSource\` is a moved module's old directory points at the new one, in this site's checkout of the target repository. Refuses a target repository the site has not registered, a missing target directory, and a rename another config still depends on. | yes — restore \`.migrations/backup/${id}/<file>\` |"
        # insert after the last migration row of the "What ships here now" table
        n="$(grep -n '^| `[0-9]\{4\}-' "${readme}" | tail -1 | cut -d: -f1)"
        if [[ -n "${n}" ]]; then
            { head -n "${n}" "${readme}"; echo "${row}"; tail -n +"$((n + 1))" "${readme}"; } > "${readme}.tmp" && mv "${readme}.tmp" "${readme}"
        fi
    fi
    info "migration: new ${mig#${ROOT}/} (+ its fixture test)"
fi
line="${FROM}|${TO}"
table="$(sed -n '/^MOVES=(/,/^)/p' "${mig}")"
if grep -qF "\"${FROM}|" <<< "${table}"; then
    die "${FROM} is already moved in ${mig##*/}"
fi
if grep -qF "|${FROM}\"" <<< "${table}"; then
    # Moved again in the same session: A→B then B→C is one move, A→C — a site
    # never saw B.
    sed -i.bak "s#|${FROM}\"#|${TO}\"#" "${mig}" && rm -f "${mig}.bak"
    info "migration: ${mig##*/} — an earlier move now ends at ${TO}"
else
    awk -v l="    \"${line}\"" '/^MOVES=\(/{inm=1} inm && /^\)/{print l; inm=0} {print}' "${mig}" > "${mig}.tmp" \
        && cat "${mig}.tmp" > "${mig}" && rm -f "${mig}.tmp"
    info "migration: ${mig##*/} — added ${FROM} → ${TO}"
fi
info ""
info "Next: run ${TEST_DIR#${ROOT}/}/test-migration-$(basename "${mig}" | cut -c1-4)-modules-moved.sh, then commit the move,"
info "the catalogue and the migration together. Until committed, further moves join the same migration."
