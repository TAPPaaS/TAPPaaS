#!/usr/bin/env bash
#
# validate-catalog.sh — does a repository's module catalog say true things? (#463)
#
# A catalog answers two questions: where a module is, and which VMID block it
# takes. This checks that the answers hold — against the schema
# (schemas/module-catalog-fields.json) and against the repository itself, which
# a schema cannot do: a `moduleJson` that exists, a `stack` that agrees with the
# module's own, a module in the tree and not in the catalog.
#
# Written in jq, not jsonschema: the mothership has jq everywhere and a Python
# jsonschema nowhere, and the shape is small enough that a schema validator
# would add a dependency to check eight fields.
#
# WARNS by default and exits 0 — every repository predates this check, and a
# catalog that is merely out of date must not stop an operator adding a
# repository or running an update. `--strict` exits 1 on any finding: that is
# what CI and a contributor run before opening a pull request.
#
# Usage: validate-catalog.sh <repo-path|catalog-file> [--strict] [--quiet]
# Exit:  0 clean, or findings without --strict · 1 findings with --strict · 2 usage
#
set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
STRICT=0; QUIET=0; TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1 ;;
        --quiet)  QUIET=1 ;;
        -h|--help) sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "${SCRIPT_NAME}: unknown option $1" >&2; exit 2 ;;
        *)  [[ -z "${TARGET}" ]] || { echo "${SCRIPT_NAME}: unexpected argument $1" >&2; exit 2; }; TARGET="$1" ;;
    esac
    shift
done
[[ -n "${TARGET}" ]] || { echo "usage: ${SCRIPT_NAME} <repo-path|catalog-file> [--strict] [--quiet]" >&2; exit 2; }

YW=$'\033[33m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'; CL=$'\033[m'
FINDINGS=0
say()  { [[ "${QUIET}" -eq 1 ]] || echo "$*"; }
flag() { FINDINGS=$((FINDINGS + 1)); echo "${YW}[Warning]${CL} catalog: $*" >&2; }

# The catalog file, and the repository root it belongs to.
if [[ -d "${TARGET}" ]]; then
    ROOT="${TARGET%/}"
    for c in "${ROOT}/src/module-catalog.json" "${ROOT}/src/modules.json"; do
        [[ -f "${c}" ]] && { CATALOG="${c}"; break; }
    done
    [[ -n "${CATALOG:-}" ]] || { echo "${RD}[Error]${CL} no module catalog under ${ROOT}/src" >&2; exit 2; }
else
    CATALOG="${TARGET}"
    [[ -f "${CATALOG}" ]] || { echo "${RD}[Error]${CL} no such catalog: ${CATALOG}" >&2; exit 2; }
    ROOT="$(cd "$(dirname "${CATALOG}")/.." && pwd)"
fi
jq empty "${CATALOG}" 2>/dev/null || { echo "${RD}[Error]${CL} ${CATALOG} is not valid JSON" >&2; exit 1; }

say "Checking $(basename "${CATALOG}") in ${ROOT}"

# ── shape ────────────────────────────────────────────────────────────
if jq -e '(.modules | type) == "array"' "${CATALOG}" >/dev/null 2>&1; then
    SHAPE=flat
    ENTRIES='.modules'
else
    SHAPE=legacy
    ENTRIES='((.foundationModules // []) + (.applicationModules // []) + (.proxmoxTemplates // []) + (.testModules // []))'
    flag "this catalog still uses the pre-#463 lists (foundationModules/…). Move the entries into one \`modules\` list; \`stack\` on each says what the list said."
fi

# ── per entry: the fields, their form, and what they point at ────────
ALLOWED_FLAT='["moduleName","legacyName","moduleJson","vmid","stack"]'
ALLOWED_LEGACY='["moduleName","legacyName","moduleJson","vmid","stack","category","status","tier","source","repo"]'
allowed="${ALLOWED_FLAT}"; [[ "${SHAPE}" == legacy ]] && allowed="${ALLOWED_LEGACY}"

# \001, not tab: tab is IFS WHITESPACE, so `read` folds a run of them into one
# delimiter and an entry with no vmid shifts its stack into that field (the same
# trap resolve-module.sh documents for its repository feed).
while IFS=$'\001' read -r name mjson vmid stack extra; do
    [[ -n "${name}${mjson}" ]] || continue
    [[ "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || flag "'${name}': not a usable module name"
    if [[ -z "${mjson}" || "${mjson}" == null ]]; then
        flag "'${name}': no moduleJson — the catalog cannot say where it is"
    elif [[ ! -f "${ROOT}/${mjson}" ]]; then
        flag "'${name}': moduleJson ${mjson} does not exist in this repository"
    else
        # the two deliberate duplications must agree with the module itself
        m_stack="$(jq -r '.stack // empty' "${ROOT}/${mjson}" 2>/dev/null)"
        m_vmid="$(jq -r '(.vmid // (.config? // {} | to_entries[]?.value.vmid?)) // empty' "${ROOT}/${mjson}" 2>/dev/null | head -1)"
        [[ -n "${stack}" && "${stack}" != null && -n "${m_stack}" && "${stack}" != "${m_stack}" ]] \
            && flag "'${name}': catalog stack '${stack}' but the module says '${m_stack}'"
        [[ -n "${vmid}" && "${vmid}" != null && -n "${m_vmid}" && "${vmid}" != "${m_vmid}" ]] \
            && flag "'${name}': catalog vmid ${vmid} but the module says ${m_vmid}"
    fi
    [[ -n "${stack}" && "${stack}" != null && ! "${stack}" =~ ^[a-z][a-z0-9-]*$ ]] \
        && flag "'${name}': stack '${stack}' is not lower-case-with-hyphens"
    [[ -n "${extra}" ]] && flag "'${name}': field(s) the schema does not define: ${extra}"
done < <(jq -r --argjson allowed "${allowed}" "
    ${ENTRIES}[] | [ (.moduleName // \"\"), (.moduleJson // \"\"), (.vmid // \"\" | tostring), (.stack // \"\"),
                     ((keys - \$allowed) | join(\",\")) ] | join(\"\u0001\")" "${CATALOG}" 2>/dev/null)

# ── across entries: one name, one VMID ───────────────────────────────
while read -r n c; do [[ -z "${n}" ]] || flag "'${n}' appears ${c} times — a name resolves to one module"; done \
    < <(jq -r "${ENTRIES} | map(.moduleName) | group_by(.) | map(select(length > 1)) | .[] | \"\(.[0]) \(length)\"" "${CATALOG}" 2>/dev/null)
while read -r v c; do [[ -z "${v}" ]] || flag "VMID ${v} is claimed by ${c} modules — a block belongs to one"; done \
    < <(jq -r "${ENTRIES} | map(select(.vmid != null and .vmid != 0) | .vmid) | group_by(.) | map(select(length > 1)) | .[] | \"\(.[0]) \(length)\"" "${CATALOG}" 2>/dev/null)

# ── the repository: a module the catalog does not list ───────────────
listed="$(jq -r "${ENTRIES}[].moduleJson // empty" "${CATALOG}" 2>/dev/null | sort -u)"
while IFS= read -r f; do
    rel="${f#"${ROOT}"/}"
    d="$(basename "$(dirname "${f}")")"; b="$(basename "${f}" .json)"
    [[ "${d}" == "${b}" ]] || continue                       # a module's own JSON is named after its directory
    grep -qxF "${rel}" <<< "${listed}" || flag "${rel} is a module in this repository that the catalog does not list"
done < <(find "${ROOT}/src" -mindepth 3 -maxdepth 3 -name '*.json' 2>/dev/null | sort)

if [[ "${FINDINGS}" -eq 0 ]]; then
    say "${GN}✓${CL} catalog is consistent ($(jq -r "${ENTRIES} | length" "${CATALOG}") entries)"
    exit 0
fi
say "${FINDINGS} finding(s)$([[ "${STRICT}" -eq 1 ]] && echo " — --strict" || echo " — reported, not fatal")"
[[ "${STRICT}" -eq 1 ]] && exit 1
exit 0
