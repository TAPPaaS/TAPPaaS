#!/usr/bin/env bash
#
# Script Name: generate-module-dependencies.sh
# Description: Regenerate src/module-dependencies.md — the mermaid dependency
#              graph of all TAPPaaS modules — computed from each module's
#              <module>.json (dependsOn: "provider:service" entries).
#              Apps come from src/apps/*, foundation modules from
#              src/foundation/* (a module = a directory containing
#              <dirname>.json). 00-Template is skipped.
# Usage: src/generate-module-dependencies.sh [--check] [--output FILE]
#

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly VERSION="1.0.0"
readonly DEFAULT_OUTPUT="${SCRIPT_DIR}/module-dependencies.md"

CHECK_MODE=false
OUTPUT_FILE="${DEFAULT_OUTPUT}"
LOG_LEVEL="INFO"

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Description:
    Regenerates the module dependency graph (mermaid) from the module json
    files under src/apps/ and src/foundation/. The graph shows every module
    as a node (grouped Applications / Foundation) and one labeled edge per
    dependsOn entry: consumer -->|service| provider.

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
    [[ -n "${TMP_FILE:-}" && -f "${TMP_FILE:-}" ]] && rm -f "${TMP_FILE}"
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
    local apps foundation name json dep provider service
    apps="$(list_modules "${SCRIPT_DIR}/apps")"
    foundation="$(list_modules "${SCRIPT_DIR}/foundation")"

    [[ -n "${apps}${foundation}" ]] || die "No modules found under ${SCRIPT_DIR}"

    cat << 'HEADER'
# TAPPaaS Module Dependency Graph

Arrows point from a **consumer** module to the **provider** module it depends on, labeled with the service used (`dependsOn: "provider:service"`). Foundation/provider modules sit at the bottom; applications at the top.

HEADER
    printf '_Generated: %s by %s — do not edit by hand._\n\n' \
        "$(date '+%Y-%m-%d')" "${SCRIPT_NAME}"
    printf '```mermaid\ngraph TD\n'

    printf '    subgraph Applications\n'
    while IFS=$'\t' read -r name json; do
        [[ -n "${name}" ]] && printf '        %s\n' "${name}"
    done <<< "${apps}"
    printf '    end\n'

    printf '    subgraph Foundation\n'
    while IFS=$'\t' read -r name json; do
        [[ -n "${name}" ]] && printf '        %s\n' "${name}"
    done <<< "${foundation}"
    printf '    end\n\n'

    # Edges: one per dependsOn entry, consumer -->|service| provider
    while IFS=$'\t' read -r name json; do
        [[ -n "${name}" ]] || continue
        while IFS= read -r dep; do
            [[ -n "${dep}" ]] || continue
            provider="${dep%%:*}"
            service="${dep#*:}"
            printf '    %s -->|%s| %s\n' "${name}" "${service}" "${provider}"
            log_debug "edge: ${name} -->|${service}| ${provider}"
        done < <(jq -r '.dependsOn[]? // empty' "${json}")
    done <<< "${apps}"$'\n'"${foundation}"

    printf '```\n'
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
