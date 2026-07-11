#!/usr/bin/env bash
#
# Script Name: generate-module-dependencies.sh
# Description: Regenerate src/module-dependencies.md — the module dependency
#              model — computed from each module's <module>.json
#              (dependsOn: "provider:service" entries). Three views: a table
#              of near-universal "plumbing" services (consumed by >=
#              PLUMBING_MIN modules), a compact mermaid graph of the
#              remaining application topology, and a complete per-module
#              reference table. Apps come from src/apps/*, foundation
#              modules from src/foundation/* (a module = a directory
#              containing <dirname>.json). 00-Template is skipped.
# Usage: src/generate-module-dependencies.sh [--check] [--output FILE]
#

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly VERSION="1.0.0"
readonly DEFAULT_OUTPUT="${SCRIPT_DIR}/module-dependencies.md"
# A service consumed by at least this many modules is "plumbing" (tabled, not drawn).
readonly PLUMBING_MIN=5

CHECK_MODE=false
OUTPUT_FILE="${DEFAULT_OUTPUT}"
LOG_LEVEL="INFO"

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Description:
    Regenerates the module dependency model from the module json files under
    src/apps/ and src/foundation/. Output has three views: (1) a table of
    plumbing services consumed by >= ${PLUMBING_MIN} modules, (2) a compact
    mermaid graph of the remaining application topology (services between the
    same pair merged into one edge, providers without a module in this repo
    marked external), (3) a complete per-module dependency reference table.

Options:
    -h, --help          Show this help message and exit
    -d, --debug         Enable debug logging
    -c, --check         Do not write; exit 2 if ${DEFAULT_OUTPUT##*/} is out
                        of date (for CI / pre-commit use)
    -o, --output FILE   Write to FILE instead of ${DEFAULT_OUTPUT##*/}

Examples:
    ${SCRIPT_NAME}              # regenerate src/module-dependencies.md
    ${SCRIPT_NAME} --check      # verify the committed graph is current

Version: ${VERSION}
EOF
}

log() {
    local level="$1"
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "${LOG_LEVEL}" == "DEBUG" ]] && log "DEBUG" "$@" || true; }

die() {
    log_error "$@"
    exit 1
}

check_command() {
    command -v "$1" &> /dev/null || die "Required command not found: $1"
}

cleanup() {
    [[ -n "${TMP_FILE:-}" && -f "${TMP_FILE:-}" ]] && rm -f "${TMP_FILE}" || true
}
trap cleanup EXIT INT TERM

# Print "name<TAB>json-path" for every module in a directory tree.
# A module is a directory containing a json named after the directory.
list_modules() {
    local base="$1" dir name json
    for dir in "${base}"/*/; do
        name="$(basename "${dir}")"
        [[ "${name}" == "00-Template" ]] && continue
        json="${dir}${name}.json"
        [[ -f "${json}" ]] && printf '%s\t%s\n' "${name}" "${json}"
    done
}

# Emit the full markdown document on stdout.
emit_graph() {
    local apps foundation name json dep provider service edges
    apps="$(list_modules "${SCRIPT_DIR}/apps")"
    foundation="$(list_modules "${SCRIPT_DIR}/foundation")"

    [[ -n "${apps}${foundation}" ]] || die "No modules found under ${SCRIPT_DIR}"

    # Collect every edge as "consumer<TAB>provider<TAB>service" plus the module list.
    local edges_file modules_file
    edges_file="$(mktemp)" ; modules_file="$(mktemp)"
    while IFS=$'\t' read -r name json; do
        [[ -n "${name}" ]] || continue
        echo "${name}" >> "${modules_file}"
        while IFS= read -r dep; do
            [[ -n "${dep}" ]] || continue
            printf '%s\t%s\t%s\n' "${name}" "${dep%%:*}" "${dep#*:}" >> "${edges_file}"
        done < <(jq -r '.dependsOn[]? // empty' "${json}")
    done <<< "${apps}"$'\n'"${foundation}"

    local total_modules total_edges
    total_modules="$(wc -l < "${modules_file}" | tr -d ' ')"
    total_edges="$(wc -l < "${edges_file}" | tr -d ' ')"

    cat << 'HEADER'
# TAPPaaS Module Dependency Model

Computed from every module's `<module>.json` (`dependsOn: "provider:service"`).
Three views: the platform plumbing every module uses, the application topology
worth drawing, and the complete per-module reference.

HEADER
    printf '_Generated: %s by %s from %s modules / %s dependencies — do not edit by hand._\n\n' \
        "$(date '+%Y-%m-%d')" "${SCRIPT_NAME}" "${total_modules}" "${total_edges}"

    # ---- Part 1: plumbing = services consumed by >= PLUMBING_MIN modules ----
    printf '## 1. Platform plumbing\n\n'
    printf 'These foundation services are consumed near-universally; drawing them would\n'
    printf 'bury the interesting structure. A module uses them unless its entry in the\n'
    printf 'reference below says otherwise.\n\n'
    printf '| Service | Consumers (of %s modules) |\n|---------|----------|\n' "${total_modules}"
    awk -F'\t' -v min="${PLUMBING_MIN}" \
        '{ svc=$2":"$3; n[svc]++ } END { for (s in n) if (n[s] >= min) printf "| `%s` | %d |\n", s, n[s] }' \
        "${edges_file}" | sort -t'|' -k3 -rn

    # plumbing service list for filtering
    local plumbing
    plumbing="$(awk -F'\t' -v min="${PLUMBING_MIN}" \
        '{ svc=$2":"$3; n[svc]++ } END { for (s in n) if (n[s] >= min) print s }' "${edges_file}")"

    # ---- Part 2: topology graph of the remaining edges, vertical ----
    printf '\n## 2. Application topology\n\n'
    printf 'Everything that is *not* plumbing — the dependencies that shape the platform.\n'
    printf 'Multiple services between the same pair are merged into one labeled edge;\n'
    printf 'providers marked `(external)` have no module in this repo yet.\n\n'
    printf '```mermaid\ngraph TD\n'
    # merge services per consumer->provider pair, skipping plumbing edges
    awk -F'\t' -v plumb="${plumbing//$'\n'/,}," '
        BEGIN { split(plumb, arr, ","); for (i in arr) if (arr[i] != "") p[arr[i]] = 1 }
        { svc = $2 ":" $3; if (svc in p) next
          key = $1 "\t" $2
          lbl[key] = (key in lbl) ? lbl[key] ", " $3 : $3 }
        END { for (k in lbl) { split(k, a, "\t"); printf "    %s -->|\"%s\"| %s\n", a[1], lbl[k], a[2] } }' \
        "${edges_file}" | sort
    # style providers that are not modules in this repo
    awk -F'\t' -v plumb="${plumbing//$'\n'/,}," '
        BEGIN { split(plumb, arr, ","); for (i in arr) if (arr[i] != "") p[arr[i]] = 1 }
        NR == FNR { mod[$1] = 1; next }
        { svc = $2 ":" $3; if (svc in p) next; if (!($2 in mod)) ext[$2] = 1 }
        END { for (e in ext) printf "    %s[\"%s (external)\"]:::ext\n", e, e
              if (length(ext)) print "    classDef ext stroke-dasharray: 5 5" }' \
        "${modules_file}" "${edges_file}" | sort
    printf '```\n'

    # ---- Part 3: complete per-module reference ----
    printf '\n## 3. Complete reference\n\n'
    printf 'Every dependency of every module, verbatim from the json contracts.\n\n'
    printf '| Module | Depends on |\n|--------|------------|\n'
    while IFS= read -r name; do
        local list
        list="$(awk -F'\t' -v m="${name}" '$1 == m { printf "`%s:%s` ", $2, $3 }' "${edges_file}")"
        [[ -z "${list}" ]] && list="—"
        printf '| **%s** | %s |\n' "${name}" "${list}"
    done < <(sort "${modules_file}")

    rm -f "${edges_file}" "${modules_file}"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            -d|--debug)  LOG_LEVEL="DEBUG"; shift ;;
            -c|--check)  CHECK_MODE=true; shift ;;
            -o|--output) [[ $# -ge 2 ]] || die "--output requires a file argument"
                         OUTPUT_FILE="$2"; shift 2 ;;
            *)           die "Unknown option: $1 (see --help)" ;;
        esac
    done

    check_command jq

    TMP_FILE="$(mktemp)"
    emit_graph > "${TMP_FILE}"

    if [[ "${CHECK_MODE}" == true ]]; then
        # Compare ignoring the volatile _Generated:_ line.
        if diff -q <(grep -v '^_Generated:' "${OUTPUT_FILE}" 2>/dev/null) \
                   <(grep -v '^_Generated:' "${TMP_FILE}") > /dev/null; then
            log_info "${OUTPUT_FILE##*/} is up to date"
            exit 0
        else
            log_error "${OUTPUT_FILE##*/} is OUT OF DATE — run ${SCRIPT_NAME} to regenerate"
            exit 2
        fi
    fi

    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    TMP_FILE=""
    log_info "Wrote ${OUTPUT_FILE}"
}

main "$@"
